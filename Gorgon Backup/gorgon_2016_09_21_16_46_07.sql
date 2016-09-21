--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: gorgon; Type: SCHEMA; Schema: -; Owner: operator
--

CREATE SCHEMA gorgon;


ALTER SCHEMA gorgon OWNER TO operator;

SET search_path = gorgon, pg_catalog;

--
-- Name: cleanup(); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION cleanup() RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare

begin
  delete from application_metrics;
  delete from schema_metrics;
  delete from server_metrics;
  delete from applications;
  delete from schemas;
  return 0;
end;
$$;


ALTER FUNCTION gorgon.cleanup() OWNER TO operator;

--
-- Name: cleanup_server(integer); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION cleanup_server(p_server_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare

begin
  delete from application_metrics where application_id in 
	(select a.application_id
	   from schemas s, applications a
	  where s.server_id = p_server_id
	    and s.schema_id = a.schema_id);
	    
  delete from schema_metrics where schema_id in 
	(select s.schema_id
	   from schemas s
	  where s.server_id = p_server_id);

  delete from server_metrics where server_id = p_server_id;
  
  delete from applications where application_id in 
	(select a.application_id
	   from schemas s, applications a
	  where s.server_id = p_server_id
	    and s.schema_id = a.schema_id);
	    
  delete from schemas where schema_id in 
	(select s.schema_id
	   from schemas s
	  where s.server_id = p_server_id);
  return 0;
end;
$$;


ALTER FUNCTION gorgon.cleanup_server(p_server_id integer) OWNER TO operator;

--
-- Name: gather_metric_application_central(integer, text, integer, text, integer, integer); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION gather_metric_application_central(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text, p_app_id integer, p_app_internal_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_snapshot_id integer;
  v_dblink_retval text;
  v_metric_num_value double precision;
  v_metric_char_value text;
  v_sql text;
  v_bool integer;
  v_idx integer;

  crs_n cursor for select metric_id, metric_value_index from metrics where metric_type = 'N' and metric_scope = 'C' and active =true;
  crs_c cursor for select metric_id, metric_value_index from metrics where metric_type = 'C' and metric_scope = 'C' and active =true;

  crs_list cursor for select metric_num_value, metric_char_value from public.dblink_fetch(p_server_name, 'cast_list', 1000) AS tab1 (metric_num_value double precision, metric_char_value text);
begin

  --get application last snapshot id   
  select public.dblink_open(p_server_name, 'last_snapshot_id', 
    'select snapshot_id from dss_snapshots' ||
    ' where application_id = ' || p_app_internal_id ||
    '   and functional_date = (select max(functional_date)' ||
    '              from dss_snapshots where application_id =' || p_app_internal_id || ')') into v_dblink_retval;

  if v_dblink_retval = 'OK' then 
    select snapshot_id from public.dblink_fetch(p_server_name, 'last_snapshot_id', 1) AS (snapshot_id integer) into v_snapshot_id;

    perform public.dblink_close(p_server_name, 'last_snapshot_id');
  else
    perform pg_notify(p_channel, 'Error: Unable to open cursor "last_snapshot_id"');
    return -1;
  end if;

  --list through 'N' metrics and retrive their value
  for r in crs_n loop
    --retrieve value
    select public.dblink_open(p_server_name, 'metric_num_value', 
      'select metric_num_value' ||
      '  from dss_metric_results' ||
      ' where object_id =' || p_app_internal_id ||
      '   and metric_id = ' || r.metric_id ||
      '   and metric_value_index = ' || r.metric_value_index) into v_dblink_retval;

    if v_dblink_retval = 'OK' then 
      select metric_num_value from public.dblink_fetch(p_server_name, 'metric_num_value', 1) AS (metric_num_value double precision) into v_metric_num_value;

      perform public.dblink_close(p_server_name, 'metric_num_value');

      --save it to application_metrics
      insert into application_metrics values (p_app_id, r.metric_id, 1, v_metric_num_value, null);
    else
      perform pg_notify(p_channel, 'Error: Unable to open cursor "metric_num_value" for metric ' || r.metric_id);
    end if;

  end loop;

  --list through 'C' metrics and retrive their value
  for r in crs_c loop
    --retrieve value
    select public.dblink_open(p_server_name, 'metric_char_value', 
      'select metric_char_value' ||
      '  from dss_metric_results' ||
      ' where object_id =' || p_app_internal_id ||
      '   and metric_id = ' || r.metric_id ||
      '   and metric_value_index = ' || r.metric_value_index) into v_dblink_retval;

    if v_dblink_retval = 'OK' then 
      select metric_char_value from public.dblink_fetch(p_server_name, 'metric_char_value', 1) AS (metric_char_value text) into v_metric_char_value;

      perform public.dblink_close(p_server_name, 'metric_char_value');

      --save it to application_metrics
      insert into application_metrics values (p_app_id, r.metric_id, 1, null, v_metric_char_value);
    else
      perform pg_notify(p_channel, 'Error: Unable to open cursor "metric_char_value" for metric ' || r.metric_id);
    end if;

  end loop;
  return 0;
  exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (gather_metric_application_central): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;  
end;
$$;


ALTER FUNCTION gorgon.gather_metric_application_central(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text, p_app_id integer, p_app_internal_id integer) OWNER TO operator;

--
-- Name: gather_schema_central_metrics(integer, text, integer, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION gather_schema_central_metrics(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_dblink_retval text;
  v_metric_num_value double precision;
  v_metric_char_value text;
  v_sql text;
  v_bool integer;
  v_idx integer;

  crs_n cursor for select metric_id, metric_value_index from metrics where metric_type = 'N' and metric_scope = 'C' and active =true;
  crs_c cursor for select metric_id, metric_value_index from metrics where metric_type = 'C' and metric_scope = 'C' and active =true;
  crs_l cursor for select metric_id, list_sql from metrics where metric_type = 'L' and metric_scope = 'C' and active =true;

  crs_list cursor for select num_value, num_value2, num_value3, char_value, char_value2, char_value3 from public.dblink_fetch(p_server_name, 'cast_list', 1000) AS tab1 (num_value double precision, num_value2 double precision, num_value3 double precision, char_value text, char_value2 text, char_value3 text);
  p_channel text := 'gorgon';
begin
  perform pg_notify(p_channel, 'Gathering metrics for central base "' || p_schema_name || '"');
  return 0;
  --list through 'L' metrics and retrive their value
  for r in crs_l loop
    --replace variables in sql
    select replace(r.list_sql, '#SCHEMA_NAME#', p_schema_name || '.') into v_sql;

    --retrieve values
    select public.dblink_open(p_server_name, 'cast_list', v_sql) into v_dblink_retval;
    v_idx := 1;
    if v_dblink_retval = 'OK' then
      loop
        v_bool := 0;
        for s in crs_list loop
          --save it to server metrics
          insert into schema_metrics values (p_server_id, r.metric_id, v_idx, s.num_value, s.num_value2, s.num_value3, s.char_value,s.char_value2,s.char_value3);
          v_bool := 1;
          v_idx := v_idx + 1;
        end loop;
 
        if v_bool = 0 then
          exit;
        end if;
      end loop;
      perform public.dblink_close(p_server_name, 'cast_list');
    else
      perform pg_notify(p_channel, 'Error: Unable to open cursor "cast_list" for metric ' || r.metric_id);
    end if;    
  end loop;  
  return 0;
  exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (gather_schema_central_metrics): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;    
end;
$$;


ALTER FUNCTION gorgon.gather_schema_central_metrics(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) OWNER TO operator;

--
-- Name: gather_schema_local_metrics(integer, text, integer, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION gather_schema_local_metrics(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_dblink_retval text;
  v_metric_num_value double precision;
  v_metric_char_value text;
  v_sql text;
  v_bool integer;
  v_idx integer;

  crs_n cursor for select metric_id, metric_value_index from metrics where metric_type = 'N' and metric_scope = 'L' and active =true;
  crs_c cursor for select metric_id, metric_value_index from metrics where metric_type = 'C' and metric_scope = 'L' and active =true;
  crs_l cursor for select metric_id, list_sql from metrics where metric_type = 'L' and metric_scope = 'L' and active =true;

  crs_list cursor for select num_value, num_value2, num_value3, char_value, char_value2, char_value3 from public.dblink_fetch(p_server_name, 'cast_local_metric_list', 1000) AS tab1 (num_value double precision, num_value2 double precision, num_value3 double precision, char_value text, char_value2 text, char_value3 text);
  p_channel text := 'gorgon';
begin
  perform pg_notify(p_channel, 'Gathering metrics for local base "' || p_schema_name || '"');
  --list through 'L' metrics and retrive their value
  for r in crs_l loop
    --replace variables in sql
    select replace(r.list_sql, '#SCHEMA_NAME#', p_schema_name || '.') into v_sql;

    --ACTIVATE IF ADDITIONAL LOG IS NEEDED
    --perform pg_notify(p_channel, ' - Collection metric ' || r.metric_id);

    --retrieve values
    select public.dblink_open(p_server_name, 'cast_local_metric_list', v_sql) into v_dblink_retval;
    v_idx := 1;

    if v_dblink_retval = 'OK' then
      loop
        v_bool := 0;
        for s in crs_list loop

          --save it to server metrics
          insert into schema_metrics values (p_schema_id, r.metric_id, v_idx, s.num_value, s.num_value2, s.num_value3, s.char_value,s.char_value2,s.char_value3);
          v_bool := 1;
          v_idx := v_idx + 1;
          
        end loop;
 
        if v_bool = 0 then
          exit;
        end if;
      end loop;
    
  
      perform public.dblink_close(p_server_name, 'cast_local_metric_list');
    else
      perform pg_notify(p_channel, 'Error: Unable to open cursor "cast_local_metric_list" for metric ' || r.metric_id);
    end if;    
  end loop;  
return 0;
  exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (gather_schema_local_metrics): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;  
end;
$$;


ALTER FUNCTION gorgon.gather_schema_local_metrics(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) OWNER TO operator;

--
-- Name: gather_schema_mngt_metrics(integer, text, integer, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION gather_schema_mngt_metrics(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_dblink_retval text;
  v_metric_num_value double precision;
  v_metric_char_value text;
  v_sql text;
  v_bool integer;
  v_idx integer;

  crs_n cursor for select metric_id, metric_value_index from metrics where metric_type = 'N' and metric_scope = 'M' and active = true;
  crs_c cursor for select metric_id, metric_value_index from metrics where metric_type = 'C' and metric_scope = 'M' and active = true;
  crs_l cursor for select metric_id, list_sql from metrics where metric_type = 'L' and metric_scope = 'M' and active = true;

  crs_list cursor for select num_value, num_value2, num_value3, char_value, char_value2, char_value3 from public.dblink_fetch(p_server_name, 'cast_mngt_metric_list', 1000) AS tab1 (num_value double precision, num_value2 double precision, num_value3 double precision, char_value text, char_value2 text, char_value3 text);
  p_channel text := 'gorgon';
begin
  perform pg_notify(p_channel, 'Gathering metrics for management base "' || p_schema_name || '"');
  --list through 'L' metrics and retrive their value
  for r in crs_l loop
    --replace variables in sql
    select replace(r.list_sql, '#SCHEMA_NAME#', p_schema_name || '.') into v_sql;
    --retrieve values
    select public.dblink_open(p_server_name, 'cast_mngt_metric_list', v_sql) into v_dblink_retval;
    v_idx := 1;

    if v_dblink_retval = 'OK' then
      loop
        v_bool := 0;
        for s in crs_list loop

          --save it to server metrics
          insert into schema_metrics values (p_schema_id, r.metric_id, v_idx, s.num_value, s.num_value2, s.num_value3, s.char_value,s.char_value2,s.char_value3);
          v_bool := 1;
          v_idx := v_idx + 1;
          
        end loop;
 
        if v_bool = 0 then
          exit;
        end if;
      end loop;
    
  
      perform public.dblink_close(p_server_name, 'cast_mngt_metric_list');
    else
      perform pg_notify(p_channel, 'Error: Unable to open cursor "cast_mngt_metric_list" for metric ' || r.metric_id);
    end if;    
  end loop;  
  return 0;
    exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (gather_schema_mngt_metrics): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;  
end;
$$;


ALTER FUNCTION gorgon.gather_schema_mngt_metrics(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) OWNER TO operator;

--
-- Name: gather_server_metrics(integer, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION gather_server_metrics(p_server_id integer, p_server_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_dblink_retval text;
  v_metric_num_value double precision;
  v_metric_char_value text;
  v_sql text;
  v_bool integer;
  v_idx integer;

  crs_n cursor for select metric_id, metric_value_index from metrics where metric_type = 'N' and metric_scope = 'S' and active =true;
  crs_c cursor for select metric_id, metric_value_index from metrics where metric_type = 'C' and metric_scope = 'S' and active =true;
  crs_l cursor for select metric_id, list_sql from metrics where metric_type = 'L' and metric_scope = 'S' and active =true;

  crs_list cursor for select num_value, num_value2, num_value3, char_value, char_value2, char_value3 from public.dblink_fetch(p_server_name, 'cast_list', 1000) AS tab1 (num_value double precision, num_value2 double precision, num_value3 double precision, char_value text, char_value2 text, char_value3 text);
begin
  --list through 'L' metrics and retrive their value
  for r in crs_l loop
    --replace variables in sql
    select replace(r.list_sql, '#SCHEMA_NAME#', '') into v_sql;

    --retrieve values
    select public.dblink_open(p_server_name, 'cast_list', v_sql) into v_dblink_retval;
    v_idx := 1;
    if v_dblink_retval = 'OK' then
      loop
        v_bool := 0;
        for s in crs_list loop
          --save it to server metrics
          insert into server_metrics values (p_server_id, r.metric_id, v_idx, s.num_value, s.num_value2, s.num_value3, s.char_value,s.char_value2,s.char_value3);
          v_bool := 1;
          v_idx := v_idx + 1;
        end loop;
 
        if v_bool = 0 then
          exit;
        end if;
      end loop;
      perform public.dblink_close(p_server_name, 'cast_list');
    else
      perform pg_notify(p_channel, 'Error: Unable to open cursor "cast__list" for metric ' || r.metric_id);
    end if;    
  end loop;  
  return 0;
    exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (gather_server_metrics): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;  
end;
$$;


ALTER FUNCTION gorgon.gather_server_metrics(p_server_id integer, p_server_name text) OWNER TO operator;

--
-- Name: install_dblink(); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION install_dblink() RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare

begin

-- IF this query return nothing Run The function via select csc.remoteCSCInstall();
-- SELECT pg_namespace.nspname, pg_proc.proname FROM pg_proc, pg_namespace WHERE pg_proc.pronamespace=pg_namespace.oid AND pg_proc.proname LIKE '%dblink%';

CREATE EXTENSION dblink;

-- Now the following query should works: SELECT dblink_connect('hostaddr=127.0.0.1 port=2280 dbname=postgres user=operator password=CastAIP');
-- Note: DNS Name are not resolved. Only IP is allow on hostaddr property
  
  return 0;
end;
$$;


ALTER FUNCTION gorgon.install_dblink() OWNER TO operator;

--
-- Name: is_schema_a_central(text, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION is_schema_a_central(p_server_name text, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_central_version text;
  
  v_dblink_retval text;
begin
  v_central_version = '';
  select public.dblink_open(p_server_name, 'central_version', 
	'select version from ' || p_schema_name || '.sys_package_version'
	' where package_name = ''ADG_FULL_CENTRAL'''
	'   and not exists(select 1 from ' || p_schema_name || '.sys_package_version where package_name = ''CWP_SERVICE'')') into v_dblink_retval;

  if v_dblink_retval = 'OK' then 
    select central_version from public.dblink_fetch(p_server_name, 'central_version', 1) AS (central_version text) into v_central_version;

    perform public.dblink_close(p_server_name, 'central_version');
  else
    raise exception 'Unable to open cursor "central_version"';
  end if;

  if v_central_version is NULL then
    return 0;
  else
    return 1;
  end if;
end;
$$;


ALTER FUNCTION gorgon.is_schema_a_central(p_server_name text, p_schema_name text) OWNER TO operator;

--
-- Name: is_schema_a_local(text, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION is_schema_a_local(p_server_name text, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_local_version text;
  
  v_dblink_retval text;
begin
  v_local_version = '';
  
  select public.dblink_open(p_server_name, 'local_version', 
	'select version from ' || p_schema_name || '.sys_package_version'
	' where package_name = ''ADG_LOCAL_APPW'''
	'   and not exists(select 1 from ' || p_schema_name || '.sys_package_version where package_name = ''CWP_SERVICE'')') into v_dblink_retval;

  if v_dblink_retval = 'OK' then 
    select local_version from public.dblink_fetch(p_server_name, 'local_version', 1) AS (local_version text) into v_local_version;

    perform public.dblink_close(p_server_name, 'local_version');
  else
    raise exception 'Unable to open cursor "local_version"';
  end if;

  if v_local_version is NULL then
    return 0;
  else
    return 1;
  end if;
end;

$$;


ALTER FUNCTION gorgon.is_schema_a_local(p_server_name text, p_schema_name text) OWNER TO operator;

--
-- Name: is_schema_a_mngt(text, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION is_schema_a_mngt(p_server_name text, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_mngt_version text;
  
  v_dblink_retval text;
begin
  v_mngt_version = '';
  select public.dblink_open(p_server_name, 'mngt_version', 
	'select version from ' || p_schema_name || '.sys_package_version'
	' where package_name = ''CORE_PMC'''
	'   and not exists(select 1 from ' || p_schema_name || '.sys_package_version where package_name = ''CWP_SERVICE'')') into v_dblink_retval;
  if v_dblink_retval = 'OK' then 
    select mngt_version from public.dblink_fetch(p_server_name, 'mngt_version', 1) AS (mngt_version text) into v_mngt_version;
    perform public.dblink_close(p_server_name, 'mngt_version');
  else
    raise exception 'Unable to open cursor "mngt_version"';
  end if;

  if v_mngt_version is NULL then
    return 0;
  else
    return 1;
  end if;
end;

$$;


ALTER FUNCTION gorgon.is_schema_a_mngt(p_server_name text, p_schema_name text) OWNER TO operator;

--
-- Name: process_schema(integer, text, integer, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION process_schema(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_central_version text;
  
  v_dblink_retval text;

  v_bool integer;

  v_app_id integer;

  crs_appinfo cursor for select app_id, app_name, system_name, nbr_of_sp from public.dblink_fetch(p_server_name, 'cast_appinfo', 1000) AS tab1 (app_id integer, app_name text, system_name text, nbr_of_sp integer);
  p_channel text := 'gorgon';
begin

  v_central_version = '';
  perform public.dblink_exec(p_server_name, 'set search_path to ' || p_schema_name);
  
  --get Version
  select public.dblink_open(p_server_name, 'central_version', 'select version from sys_package_version where package_name = ''ADG_FULL_CENTRAL''') into v_dblink_retval;

  if v_dblink_retval = 'OK' then 
    select central_version from public.dblink_fetch(p_server_name, 'central_version', 1) AS (central_version text) into v_central_version;

    perform public.dblink_close(p_server_name, 'central_version');
  else
    perform pg_notify(p_channel, 'Error: Unable to open cursor "central_version"');
    return -1;
  end if;

  --List Applications
  --Identify central schema
  select public.dblink_open(p_server_name, 'cast_appinfo', 
	'select a.object_id app_id, a.object_name application_name, s.object_name system_name, count(sp.snapshot_id) nbr_of_sp'
	'  from dss_objects a, dss_links l, dss_objects s, dss_snapshots sp'
	' where a.object_type_id = -102'
	'   and a.object_id = l.next_object_id'
	'   and l.link_type_id = 1'
	'   and l.previous_object_id = s.object_id'
	'   and s.object_type_id = -101'
	'   and a.object_id = sp.application_id'
	' group by a.object_id, a.object_name, s.object_name') into v_dblink_retval; 

  if v_dblink_retval = 'OK' then
    loop
      v_bool := 0;
      for r in crs_appinfo loop
	v_app_id := nextval('main_seq');
	insert into applications values (v_app_id, r.app_name, r.system_name, p_schema_id, p_schema_name, v_central_version, '', r.nbr_of_sp);
	--gather metrics
	perform gather_metric_application_central(p_server_id, p_server_name, p_schema_id, p_schema_name, v_app_id, r.app_id);
        v_bool := 1;
      end loop;
 
      if v_bool = 0 then
        exit;
      end if;
    end loop;
  
    perform public.dblink_close(p_server_name, 'cast_appinfo');
  else
    perform pg_notify(p_channel, 'Error: Unable to open cursor "cast_appinfo"');
  end if;
 return 0;
     exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (process_schema): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;  
end;
$$;


ALTER FUNCTION gorgon.process_schema(p_server_id integer, p_server_name text, p_schema_id integer, p_schema_name text) OWNER TO operator;

--
-- Name: process_schema_central(text, text); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION process_schema_central(p_server_name text, p_schema_name text) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_central_version text;
  
  v_dblink_retval text;
  p_channel text := 'gorgon';
begin
  v_central_version = '';
  
  select public.dblink_open(p_server_name, 'central_version', 
	'select version from ' || p_schema_name || '.sys_package_version'
	' where package_name = ''ADG_FULL_CENTRAL'''
	'   and not exists(select 1 from ' || p_schema_name || '.sys_package_version where package_name = ''CWP_SERVICE'')') into v_dblink_retval;

  if v_dblink_retval = 'OK' then 
    select central_version from public.dblink_fetch(p_server_name, 'central_version', 1) AS (central_version text) into v_central_version;

    perform public.dblink_close(p_server_name, 'central_version');
  else
    perform pg_notify(p_channel, 'Error: Unable to open cursor "central_version"');
  end if;

  if v_central_version is NULL then
    return 0;
  else
    return 1;
  end if;
     exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (process_schema_central): ' || SQLERRM || '(' || SQLSTATE || ')');
    return -1;   
end;
$$;


ALTER FUNCTION gorgon.process_schema_central(p_server_name text, p_schema_name text) OWNER TO operator;

--
-- Name: process_server(integer); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION process_server(p_server_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
  v_connection_string text;
  v_server_name text;
  v_schema_name text;
  v_bool integer;
  v_is_schema_a_central int;
  v_is_schema_a_local int;
  v_is_schema_a_mngt int;
  v_schema_id integer;
  
  crs_schemas cursor for select schemaname from public.dblink_fetch(v_server_name, 'cast_schemas', 1000) AS tab1 (schemaname text);

  v_dblink_retval text;
  p_channel text := 'gorgon';
begin
  select connection_string, server_name into v_connection_string, v_server_name from servers where server_id = p_server_id;

  perform pg_notify(p_channel, 'Cleanup previous data for server ' || v_server_name);
  perform cleanup_server(p_server_id);
  
  perform pg_notify(p_channel, 'Connecting DB link to server ' || v_server_name);
  perform public.dblink_connect(v_server_name, v_connection_string);

  -- Gather information at the Server level
  perform pg_notify(p_channel, 'Gathering Server Metrics');
  perform gather_server_metrics(p_server_id,v_server_name);

  --Identify CAST schemas
  perform pg_notify(p_channel, 'Identifying CAST Schemas...');
  select public.dblink_open(v_server_name, 'cast_schemas', 'select schemaname from pg_tables where tablename = ''sys_package_version'' and (schemaname not like ''%schemacopy%'' and schemaname not like ''%test%'' and schemaname not like ''%OLD'') order by 1') into v_dblink_retval; 

  if v_dblink_retval = 'OK' then
    loop
      v_bool := 0;
      for r in crs_schemas loop
        --check if schema is a central
        v_schema_id := nextval('main_seq');
        select is_schema_a_central(v_server_name, r.schemaname) into v_is_schema_a_central;
	if v_is_schema_a_central = 1 then
	  insert into schemas values (v_schema_id, p_server_id, 3, r.schemaname);
	  perform process_schema(p_server_id, v_server_name, v_schema_id, r.schemaname);
	  perform gather_schema_central_metrics (p_server_id,v_server_name,v_schema_id,r.schemaname);
	else 
	    select is_schema_a_local(v_server_name, r.schemaname) into v_is_schema_a_local;
	    if v_is_schema_a_local = 1 then
	      insert into schemas values (v_schema_id, p_server_id, 2, r.schemaname);
	      perform gather_schema_local_metrics (p_server_id,v_server_name,v_schema_id,r.schemaname);
	    else 
		    select is_schema_a_mngt(v_server_name, r.schemaname) into v_is_schema_a_mngt;
		    if v_is_schema_a_mngt = 1 then
		      insert into schemas values (v_schema_id, p_server_id, 1, r.schemaname);
		      perform gather_schema_mngt_metrics (p_server_id,v_server_name,v_schema_id,r.schemaname);
		    else
		      perform pg_notify(p_channel, 'Schema "' || r.schemaname || '" is not of a supported type');
		      insert into schemas values (v_schema_id, p_server_id, 0, r.schemaname);
		    end if;
	    end if;
	  
	end if;

        v_bool := 1;
      end loop;
 
      if v_bool = 0 then
        exit;
      end if;
    end loop;
    
  
    perform public.dblink_close(v_server_name, 'cast_schemas');
  else
    perform pg_notify(p_channel, 'Unable to open cursor "cast_schemas"');
  end if;

  perform pg_notify(p_channel, 'Disconnecting DB Link for server ' || v_server_name);
  perform public.dblink_disconnect(v_server_name);

  update servers set last_computed = now() where server_id = p_server_id; 
  
  return 0;
  exception when OTHERS then
    perform pg_notify(p_channel, 'Exception (process_server): ' || SQLERRM || '(' || SQLSTATE || ')');
    begin --try closing it 
      perform public.dblink_disconnect(v_server_name);
      return -1;
    exception when OTHERS then
      perform pg_notify(p_channel, 'Exception while closing db_link: ' || SQLERRM || '(' || SQLSTATE || ')');
      return -1;
    end;
end;
$$;


ALTER FUNCTION gorgon.process_server(p_server_id integer) OWNER TO operator;

--
-- Name: process_servers(); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION process_servers() RETURNS integer
    LANGUAGE plpgsql
    AS $$ 
declare
 crs cursor for select server_id from servers where active =true;
begin
  for r in crs loop
    perform process_server(r.server_id);
  end loop;
  return 0;
end;
$$;


ALTER FUNCTION gorgon.process_servers() OWNER TO operator;

--
-- Name: util_get_server_time(); Type: FUNCTION; Schema: gorgon; Owner: operator
--

CREATE FUNCTION util_get_server_time() RETURNS text
    LANGUAGE plpgsql
    AS $$declare
begin
 return to_char(now(), 'yyyy-MM-DD HH24:MI:SS');
end;
$$;


ALTER FUNCTION gorgon.util_get_server_time() OWNER TO operator;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: application_metrics; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE application_metrics (
    application_id integer NOT NULL,
    metric_id integer NOT NULL,
    idx integer DEFAULT 1 NOT NULL,
    num_value numeric,
    char_value text
);


ALTER TABLE gorgon.application_metrics OWNER TO operator;

--
-- Name: applications; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE applications (
    application_id integer NOT NULL,
    application_name character varying(255) NOT NULL,
    system_name character varying(255) NOT NULL,
    schema_id integer NOT NULL,
    schema_name character varying(255) NOT NULL,
    cast_version character varying(25),
    dashboard_password character varying(255),
    nbr_of_snapshots integer DEFAULT 0 NOT NULL
);


ALTER TABLE gorgon.applications OWNER TO operator;

--
-- Name: core_smelltest_threshholds; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE core_smelltest_threshholds (
    smelltest_name character varying(255),
    threshhold_name character varying(255),
    threshhold_value integer,
    threshhold_comment character varying(1024)
);


ALTER TABLE gorgon.core_smelltest_threshholds OWNER TO operator;

--
-- Name: core_trans_artifact_types; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE core_trans_artifact_types (
    object_type_str character varying(255),
    trans_candidate character varying(10)
);


ALTER TABLE gorgon.core_trans_artifact_types OWNER TO operator;

--
-- Name: main_seq; Type: SEQUENCE; Schema: gorgon; Owner: operator
--

CREATE SEQUENCE main_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE gorgon.main_seq OWNER TO operator;

--
-- Name: SEQUENCE main_seq; Type: COMMENT; Schema: gorgon; Owner: operator
--

COMMENT ON SEQUENCE main_seq IS 'Used by Servers, schemas and Applications';


--
-- Name: metric_result_seq; Type: SEQUENCE; Schema: gorgon; Owner: operator
--

CREATE SEQUENCE metric_result_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE gorgon.metric_result_seq OWNER TO operator;

--
-- Name: SEQUENCE metric_result_seq; Type: COMMENT; Schema: gorgon; Owner: operator
--

COMMENT ON SEQUENCE metric_result_seq IS 'Used by Appliation_Metrics, Schema_Metrics and server_metrics';


--
-- Name: metric_seq; Type: SEQUENCE; Schema: gorgon; Owner: operator
--

CREATE SEQUENCE metric_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE gorgon.metric_seq OWNER TO operator;

--
-- Name: SEQUENCE metric_seq; Type: COMMENT; Schema: gorgon; Owner: operator
--

COMMENT ON SEQUENCE metric_seq IS 'Used by Metrics';


--
-- Name: metrics; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE metrics (
    metric_id integer NOT NULL,
    metric_name character varying(255) NOT NULL,
    metric_type character(1) NOT NULL,
    metric_scope character(1) NOT NULL,
    metric_value_index integer DEFAULT 0 NOT NULL,
    list_sql text,
    description text,
    fixing_metric_id integer,
    level character varying(20),
    category character varying(255),
    mode character varying(20),
    active boolean,
    CONSTRAINT metrics_local_type_ck CHECK ((metric_type = ANY (ARRAY['N'::bpchar, 'C'::bpchar, 'L'::bpchar])))
);


ALTER TABLE gorgon.metrics OWNER TO operator;

--
-- Name: COLUMN metrics.metric_type; Type: COMMENT; Schema: gorgon; Owner: operator
--

COMMENT ON COLUMN metrics.metric_type IS 'L for List
C for Char (one row and CAST ID metric)
N for Numeric (one row and CAST ID metric)';


--
-- Name: COLUMN metrics.metric_scope; Type: COMMENT; Schema: gorgon; Owner: operator
--

COMMENT ON COLUMN metrics.metric_scope IS 'S for Server
G for Generic Schema
L for Local Base
C for Central Base
M for Management Base
A for Measurement Base
P for Application';


--
-- Name: COLUMN metrics.fixing_metric_id; Type: COMMENT; Schema: gorgon; Owner: operator
--

COMMENT ON COLUMN metrics.fixing_metric_id IS 'ID of the rule which should fix the issue';


--
-- Name: schema_metrics; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE schema_metrics (
    schema_id integer NOT NULL,
    metric_id integer NOT NULL,
    idx integer DEFAULT 1 NOT NULL,
    num_value numeric,
    num_value2 numeric,
    num_value3 numeric,
    char_value text,
    char_value2 text,
    char_value3 text
);


ALTER TABLE gorgon.schema_metrics OWNER TO operator;

--
-- Name: schema_types; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE schema_types (
    schema_type_id integer NOT NULL,
    name character varying(255) NOT NULL,
    description character varying(255) NOT NULL
);


ALTER TABLE gorgon.schema_types OWNER TO operator;

--
-- Name: schemas; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE schemas (
    schema_id integer NOT NULL,
    server_id integer NOT NULL,
    schema_type_id integer NOT NULL,
    name character varying(255) NOT NULL
);


ALTER TABLE gorgon.schemas OWNER TO operator;

--
-- Name: server_metrics; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE server_metrics (
    server_id integer NOT NULL,
    metric_id integer NOT NULL,
    idx integer DEFAULT 1 NOT NULL,
    num_value numeric,
    num_value2 numeric,
    num_value3 numeric,
    char_value text,
    char_value2 text,
    char_value3 text
);


ALTER TABLE gorgon.server_metrics OWNER TO operator;

--
-- Name: servers; Type: TABLE; Schema: gorgon; Owner: operator; Tablespace: 
--

CREATE TABLE servers (
    server_id integer NOT NULL,
    server_name character varying(255) NOT NULL,
    connection_string text,
    active boolean,
    last_computed timestamp without time zone
);


ALTER TABLE gorgon.servers OWNER TO operator;

--
-- Name: smelltest_fp_artifactratio; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW smelltest_fp_artifactratio AS
    SELECT tb_pgm_classes.application_id, tb_pgm_classes.application_name, tb_pgm_classes.pgm_classes, tb_fp.fp, CASE WHEN (tb_pgm_classes.pgm_classes = (0)::numeric) THEN (0)::numeric ELSE (tb_fp.fp / tb_pgm_classes.pgm_classes) END AS fp_to_pgmclass_ratio, 'CANT DEFINE STATUS: RANGE TOO WIDE' AS status FROM ((SELECT t2.application_id, t1.application_name, sum(t2.num_value) AS pgm_classes FROM applications t1, application_metrics t2, metrics t3 WHERE (((t1.application_id = t2.application_id) AND (t2.metric_id = t3.metric_id)) AND (t2.metric_id = ANY (ARRAY[10155, 10156]))) GROUP BY t2.application_id, t1.application_name) tb_pgm_classes JOIN (SELECT t2.application_id, t1.application_name, sum(t2.num_value) AS fp FROM applications t1, application_metrics t2, metrics t3 WHERE (((t1.application_id = t2.application_id) AND (t2.metric_id = t3.metric_id)) AND (t2.metric_id = ANY (ARRAY[10203, 10204]))) GROUP BY t2.application_id, t1.application_name) tb_fp ON ((tb_pgm_classes.application_id = tb_fp.application_id))) ORDER BY CASE WHEN (tb_pgm_classes.pgm_classes = (0)::numeric) THEN (0)::numeric ELSE (tb_fp.fp / tb_pgm_classes.pgm_classes) END;


ALTER TABLE gorgon.smelltest_fp_artifactratio OWNER TO operator;

--
-- Name: smelltest_transactionratio; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW smelltest_transactionratio AS
    SELECT tb_transaction_ratio.application_id, tb_transaction_ratio.application_name, tb_transaction_ratio.tfp, tb_transaction_ratio.dfp, tb_transaction_ratio.ratio, CASE WHEN (tb_transaction_ratio.ratio < (50)::numeric) THEN 'ISSUE'::text WHEN (tb_transaction_ratio.ratio < (100)::numeric) THEN 'AMBER'::text WHEN (tb_transaction_ratio.ratio < (300)::numeric) THEN 'PASS'::text WHEN (tb_transaction_ratio.ratio < (400)::numeric) THEN 'AMBER'::text ELSE 'ISSUE'::text END AS status FROM (SELECT app.application_id, app.application_name, tfp.num_value AS tfp, dfp.num_value AS dfp, CASE COALESCE(dfp.num_value, (0)::numeric) WHEN 0 THEN ((-1))::numeric ELSE ((tfp.num_value * (100)::numeric) / dfp.num_value) END AS ratio FROM (SELECT application_metrics.application_id, application_metrics.num_value FROM application_metrics WHERE (application_metrics.metric_id = 10203)) dfp, (SELECT application_metrics.application_id, application_metrics.num_value FROM application_metrics WHERE (application_metrics.metric_id = 10204)) tfp, applications app WHERE ((dfp.application_id = tfp.application_id) AND (dfp.application_id = app.application_id))) tb_transaction_ratio;


ALTER TABLE gorgon.smelltest_transactionratio OWNER TO operator;

--
-- Name: trans_artifact_summary; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW trans_artifact_summary AS
    SELECT sch.name, sch.name AS app_name, schm.char_value, schm.num_value AS artifact_count, schm.num_value2 AS artifact_in_tran, 0 AS application_id FROM schema_metrics schm, schemas sch WHERE ((schm.metric_id = 286) AND (schm.schema_id = sch.schema_id));


ALTER TABLE gorgon.trans_artifact_summary OWNER TO operator;

--
-- Name: trans_count_summary; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW trans_count_summary AS
    SELECT sch.name, sch.name AS app_name, schm.num_value AS count_all_transaction, schm.num_value2 AS count_empty_transaction, 0 AS application_id FROM schema_metrics schm, schemas sch WHERE ((schm.metric_id = 287) AND (schm.schema_id = sch.schema_id));


ALTER TABLE gorgon.trans_count_summary OWNER TO operator;

--
-- Name: v_cast_version_used; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_cast_version_used AS
    SELECT applications.cast_version, count(1) AS count FROM applications GROUP BY applications.cast_version ORDER BY count(1) DESC;


ALTER TABLE gorgon.v_cast_version_used OWNER TO operator;

--
-- Name: v_dotnet_package_used; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_dotnet_package_used AS
    SELECT schema_metrics.char_value, count(1) AS count FROM schema_metrics WHERE (schema_metrics.metric_id = 208) GROUP BY schema_metrics.char_value ORDER BY count(1) DESC;


ALTER TABLE gorgon.v_dotnet_package_used OWNER TO operator;

--
-- Name: v_java_package_used; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_java_package_used AS
    SELECT schema_metrics.char_value, count(1) AS count FROM schema_metrics WHERE (schema_metrics.metric_id = 9) GROUP BY schema_metrics.char_value ORDER BY count(1) DESC;


ALTER TABLE gorgon.v_java_package_used OWNER TO operator;

--
-- Name: v_metrics; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_metrics AS
    SELECT metrics.metric_id, metrics.metric_name, metrics.metric_type, metrics.metric_scope, metrics.metric_value_index, metrics.active, metrics.level, metrics.description, metrics.category, metrics.mode FROM metrics;


ALTER TABLE gorgon.v_metrics OWNER TO operator;

--
-- Name: v_orphan_technology_per_local; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_orphan_technology_per_local AS
    SELECT app.name, scm.char_value, met.metric_name, met.description FROM schema_metrics scm, schemas app, metrics met WHERE (((scm.metric_id = 5) AND (scm.schema_id = app.schema_id)) AND (met.metric_id = scm.metric_id)) ORDER BY app.name, scm.char_value;


ALTER TABLE gorgon.v_orphan_technology_per_local OWNER TO operator;

--
-- Name: v_techno_per_app; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_techno_per_app AS
    SELECT DISTINCT app.name, scm.char_value2, met.metric_name FROM schema_metrics scm, metrics met, schemas app WHERE (((scm.metric_id = 10) AND (scm.schema_id = app.schema_id)) AND (met.metric_id = scm.metric_id)) ORDER BY app.name, scm.char_value2, met.metric_name;


ALTER TABLE gorgon.v_techno_per_app OWNER TO operator;

--
-- Name: v_technology_used; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_technology_used AS
    SELECT request.char_value2, count(1) AS count FROM (SELECT schema_metrics.schema_id, schema_metrics.char_value2 FROM schema_metrics WHERE (schema_metrics.metric_id = 10) GROUP BY schema_metrics.schema_id, schema_metrics.char_value2) request GROUP BY request.char_value2 ORDER BY count(1) DESC;


ALTER TABLE gorgon.v_technology_used OWNER TO operator;

--
-- Name: v_violation; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_violation AS
    SELECT request.name, request.metric_name, request.severity, request.reference, request.assigned_to, request.status, request.problem, request.verification, request.todo FROM (SELECT DISTINCT loc.name, met.metric_name, 'Major'::text AS severity, met.metric_id AS reference, 'To define'::text AS assigned_to, 'Open'::text AS status, 'Transaction Configuration Issue'::text AS problem, 'Create a Generic Set and a rule'::text AS verification, met.description AS todo FROM schema_metrics rules, metrics met, schemas loc WHERE ((((((NOT ((rules.schema_id, rules.metric_id) IN (SELECT DISTINCT loc.schema_id, met.metric_id FROM schema_metrics rules, schema_metrics fixed, metrics met, schemas mngt, schemas loc WHERE ((((((rules.schema_id = loc.schema_id) AND (fixed.schema_id = mngt.schema_id)) AND (met.metric_id = rules.metric_id)) AND (met.fixing_metric_id = fixed.metric_id)) AND ("substring"((loc.name)::text, '([a-zA-Z0-9\-\_]+)\_[a-zA-Z0-9]+$'::text) = "substring"((mngt.name)::text, '([a-zA-Z0-9\-\_]+)\_[a-zA-Z0-9]+$'::text))) AND (met.metric_scope = 'L'::bpchar))))) AND (rules.schema_id = loc.schema_id)) AND (met.metric_id = rules.metric_id)) AND (((met.metric_name)::text ~~ 'Transaction Configuration: Use of %'::text) OR ((met.metric_name)::text ~~ 'Transaction configuration: Use of %'::text))) AND ((loc.name)::text !~~ '%old'::text)) AND ((loc.name)::text !~~ '%backup'::text)) UNION ALL SELECT DISTINCT loc.name, met.metric_name, 'Major'::text AS severity, met.metric_id AS reference, 'To define'::text AS assigned_to, 'Open'::text AS status, 'Transaction Configuration Issue'::text AS problem, 'Create a Generic Set and a rule'::text AS verification, met.description AS todo FROM schema_metrics rules, metrics met, schemas loc WHERE ((((((((met.metric_id < 29) AND (rules.idx = 1)) AND (rules.metric_id = met.metric_id)) AND ((met.mode)::bpchar = 'Issue'::bpchar)) AND ((loc.name)::text !~~ '%old'::text)) AND ((loc.name)::text !~~ '%backup'::text)) AND (rules.schema_id = loc.schema_id)) AND (met.metric_id <> ALL (ARRAY[6, 9, 10])))) request ORDER BY request.name, request.reference;


ALTER TABLE gorgon.v_violation OWNER TO operator;

--
-- Name: v_violation_java; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW v_violation_java AS
    SELECT violation.name, violation.metric_name, violation.problem, violation.verification, violation.todo FROM v_violation violation WHERE (((violation.name)::text IN (SELECT DISTINCT sch.name FROM schema_metrics schm, schemas sch WHERE (((schm.metric_id = 10) AND (schm.char_value2 = 'Java'::text)) AND (schm.schema_id = sch.schema_id)))) AND ((violation.metric_name)::text ~~ 'Transaction Configuration: Use of%'::text));


ALTER TABLE gorgon.v_violation_java OWNER TO operator;

--
-- Name: violation; Type: VIEW; Schema: gorgon; Owner: operator
--

CREATE VIEW violation AS
    SELECT request.name, request.metric_name, request.severity, request.reference, request.assigned_to, request.status, request.problem, request.verification, request.todo FROM (SELECT DISTINCT loc.name, met.metric_name, 'Major'::text AS severity, met.metric_id AS reference, 'To define'::text AS assigned_to, 'Open'::text AS status, 'Transaction Configuration Issue'::text AS problem, 'Create a Generic Set and a rule'::text AS verification, met.description AS todo FROM schema_metrics rules, metrics met, schemas loc WHERE ((((((NOT ((rules.schema_id, rules.metric_id) IN (SELECT DISTINCT loc.schema_id, met.metric_id FROM schema_metrics rules, schema_metrics fixed, metrics met, schemas mngt, schemas loc WHERE ((((((rules.schema_id = loc.schema_id) AND (fixed.schema_id = mngt.schema_id)) AND (met.metric_id = rules.metric_id)) AND (met.fixing_metric_id = fixed.metric_id)) AND ("substring"((loc.name)::text, '([a-zA-Z0-9\-\_]+)\_[a-zA-Z0-9]+$'::text) = "substring"((mngt.name)::text, '([a-zA-Z0-9\-\_]+)\_[a-zA-Z0-9]+$'::text))) AND (met.metric_scope = 'L'::bpchar))))) AND (rules.schema_id = loc.schema_id)) AND (met.metric_id = rules.metric_id)) AND (((met.metric_name)::text ~~ 'Transaction Configuration: Use of %'::text) OR ((met.metric_name)::text ~~ 'Transaction configuration: Use of %'::text))) AND ((loc.name)::text !~~ '%old'::text)) AND ((loc.name)::text !~~ '%backup'::text)) UNION ALL SELECT DISTINCT loc.name, met.metric_name, 'Major'::text AS severity, met.metric_id AS reference, 'To define'::text AS assigned_to, 'Open'::text AS status, 'Transaction Configuration Issue'::text AS problem, 'Create a Generic Set and a rule'::text AS verification, met.description AS todo FROM schema_metrics rules, metrics met, schemas loc WHERE ((((((((met.metric_id < 29) AND (rules.idx = 1)) AND (rules.metric_id = met.metric_id)) AND ((met.mode)::bpchar = 'Issue'::bpchar)) AND ((loc.name)::text !~~ '%old'::text)) AND ((loc.name)::text !~~ '%backup'::text)) AND (rules.schema_id = loc.schema_id)) AND (met.metric_id <> ALL (ARRAY[6, 9, 10])))) request ORDER BY request.name, request.reference;


ALTER TABLE gorgon.violation OWNER TO operator;

--
-- Name: application_metric_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY application_metrics
    ADD CONSTRAINT application_metric_pk PRIMARY KEY (application_id, metric_id, idx);


--
-- Name: application_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY applications
    ADD CONSTRAINT application_pk PRIMARY KEY (application_id);


--
-- Name: metrics_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY metrics
    ADD CONSTRAINT metrics_pk PRIMARY KEY (metric_id);


--
-- Name: metrics_uk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY metrics
    ADD CONSTRAINT metrics_uk UNIQUE (metric_name);


--
-- Name: schema_metric_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY schema_metrics
    ADD CONSTRAINT schema_metric_pk PRIMARY KEY (schema_id, metric_id, idx);


--
-- Name: schema_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY schemas
    ADD CONSTRAINT schema_pk PRIMARY KEY (schema_id);


--
-- Name: schema_type_id; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY schema_types
    ADD CONSTRAINT schema_type_id PRIMARY KEY (schema_type_id);


--
-- Name: server_metric_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY server_metrics
    ADD CONSTRAINT server_metric_pk PRIMARY KEY (server_id, metric_id, idx);


--
-- Name: server_pk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY servers
    ADD CONSTRAINT server_pk PRIMARY KEY (server_id);


--
-- Name: server_uk; Type: CONSTRAINT; Schema: gorgon; Owner: operator; Tablespace: 
--

ALTER TABLE ONLY servers
    ADD CONSTRAINT server_uk UNIQUE (server_name);


--
-- Name: application_schema_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY applications
    ADD CONSTRAINT application_schema_id_fk FOREIGN KEY (schema_id) REFERENCES schemas(schema_id);


--
-- Name: metric_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY application_metrics
    ADD CONSTRAINT metric_id_fk FOREIGN KEY (metric_id) REFERENCES metrics(metric_id);


--
-- Name: metric_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY server_metrics
    ADD CONSTRAINT metric_id_fk FOREIGN KEY (metric_id) REFERENCES metrics(metric_id);


--
-- Name: metric_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY schema_metrics
    ADD CONSTRAINT metric_id_fk FOREIGN KEY (metric_id) REFERENCES metrics(metric_id);


--
-- Name: schema_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY schema_metrics
    ADD CONSTRAINT schema_id_fk FOREIGN KEY (schema_id) REFERENCES schemas(schema_id);


--
-- Name: schema_type_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY schemas
    ADD CONSTRAINT schema_type_id_fk FOREIGN KEY (schema_type_id) REFERENCES schema_types(schema_type_id);


--
-- Name: server_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY schemas
    ADD CONSTRAINT server_id_fk FOREIGN KEY (server_id) REFERENCES servers(server_id);


--
-- Name: server_id_fk; Type: FK CONSTRAINT; Schema: gorgon; Owner: operator
--

ALTER TABLE ONLY server_metrics
    ADD CONSTRAINT server_id_fk FOREIGN KEY (server_id) REFERENCES servers(server_id);


--
-- PostgreSQL database dump complete
--

