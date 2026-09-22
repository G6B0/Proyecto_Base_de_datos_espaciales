@echo off
setlocal
set "QGIS_PYTHON=C:\Program Files\QGIS 3.44.13\bin\python-qgis-ltr.bat"

if not exist "%QGIS_PYTHON%" (
  echo No se encontro Python de QGIS en: %QGIS_PYTHON%
  exit /b 1
)

call "%QGIS_PYTHON%" "%~dp0download_csn_catalog.py" %*
endlocal
