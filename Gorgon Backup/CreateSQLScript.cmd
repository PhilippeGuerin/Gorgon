set hour=%time:~0,2%
if "%hour:~0,1%" == " " set hour=0%hour:~1,1%
echo hour=%hour%
set min=%time:~3,2%
if "%min:~0,1%" == " " set min=0%min:~1,1%
echo min=%min%
set secs=%time:~6,2%
if "%secs:~0,1%" == " " set secs=0%secs:~1,1%
echo secs=%secs%

set year=%date:~-4%
echo year=%year%

echo %DATE%
echo %TIME%
set datetimef=%date:~-4%_%date:~4,2%_%date:~7,2%_%time:~0,2%_%time:~3,2%_%time:~6,2%
echo %datetimef%
"C:\Program Files\CAST\CASTStorageService2\bin\pg_dump.exe" --host localhost --port 2280 --username "operator" --role "operator" --no-password   -s --file "C:\DEV\Gorgon\Gorgon Backup\gorgon_%datetimef%.sql" --schema "gorgon" "postgres"
echo  --section pre-data --verbose --format tar
echo "C:\Program Files\CAST\CASTStorageService2\bin\pg_dump.exe" -h localhost -p 2280 -U operator  -W CastAIP -s postgres  -f "C:\DEV\Gorgon\Gorgon Backup\gorgon%DATE%.sql"
echo off
echo  -s gorgon -d postgres -W CastAIP --dbname=postgres  
echo 

pause