#
################# Dangerous to use appveyor links - the builds are removed after 6 months
#
#ARG FLUENTBIT_URL=https://ci.appveyor.com/api/buildjobs/37lho3xf8j5i6crj/artifacts/build%2Ftd-agent-bit-1.4.0-win64.zip

Write-Host ('Creating folder structure')
    New-Item -Type Directory -Path /installation -ErrorAction SilentlyContinue

    New-Item -Type Directory -Path /opt/fluent-bit
    New-Item -Type Directory -Path /opt/scripts/ruby
    New-Item -Type Directory -Path /opt/telegraf

    New-Item -Type Directory -Path /etc/fluent-bit
    New-Item -Type Directory -Path /etc/fluent
    New-Item -Type Directory -Path /etc/omsagentwindows
    New-Item -Type Directory -Path /etc/telegraf

    New-Item -Type Directory -Path /etc/config/settings/
    New-Item -Type Directory -Path /etc/config/adx/

Write-Host ('Installing Fluent Bit');

    try {
        $fluentBitUri='https://fluentbit.io/releases/1.7/td-agent-bit-1.7.8-win64.zip'
        Invoke-WebRequest -Uri $fluentBitUri -OutFile /installation/td-agent-bit.zip
        Expand-Archive -Path /installation/td-agent-bit.zip -Destination /installation/fluent-bit
        Move-Item -Path /installation/fluent-bit/*/* -Destination /opt/fluent-bit/ -ErrorAction SilentlyContinue
    }
    catch {
        $e = $_.Exception
        Write-Host "exception when Installing fluent bit"
        Write-Host $e
        exit 1
    }
Write-Host ('Finished Installing Fluentbit')

Write-Host ('Installing Telegraf');
try {
    $telegrafUri='https://dl.influxdata.com/telegraf/releases/telegraf-1.18.0_windows_amd64.zip'
    Invoke-WebRequest -Uri $telegrafUri -OutFile /installation/telegraf.zip
    Expand-Archive -Path /installation/telegraf.zip -Destination /installation/telegraf
    Move-Item -Path /installation/telegraf/*/* -Destination /opt/telegraf/ -ErrorAction SilentlyContinue
}
catch {
    $ex = $_.Exception
    Write-Host "exception while downloading telegraf for windows"
    Write-Host $ex
    exit 1
}
Write-Host ('Finished downloading Telegraf')

Write-Host ('Installing Visual C++ Redistributable Package')
    $vcRedistLocation = 'https://aka.ms/vs/16/release/vc_redist.x64.exe'
    $vcInstallerLocation = "\installation\vc_redist.x64.exe"
    $vcArgs = "/install /quiet /norestart"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $vcRedistLocation -OutFile $vcInstallerLocation
    Start-Process $vcInstallerLocation -ArgumentList $vcArgs -NoNewWindow -Wait
    Copy-Item -Path /Windows/System32/msvcp140.dll -Destination /opt/fluent-bit/bin
    Copy-Item -Path /Windows/System32/vccorlib140.dll -Destination /opt/fluent-bit/bin
    Copy-Item -Path /Windows/System32/vcruntime140.dll -Destination /opt/fluent-bit/bin
Write-Host ('Finished Installing Visual C++ Redistributable Package')

Write-Host ('Extracting Certificate Generator Package')
    Expand-Archive -Path /opt/omsagentwindows/certificategenerator.zip -Destination /opt/omsagentwindows/certgenerator/ -Force
Write-Host ('Finished Extracting Certificate Generator Package')

Write-Host ("Removing Install folder")

Remove-Item /installation -Recurse

#Remove gemfile.lock for http_parser gem 0.6.0
#see  - https://github.com/fluent/fluentd/issues/3374 https://github.com/tmm1/http_parser.rb/issues/70

$gemfile = "\ruby26\lib\ruby\gems\2.6.0\gems\http_parser.rb-0.6.0\Gemfile.lock"
$gemfileFullPath = $Env:SYSTEMDRIVE + "\" + $gemfile
If (Test-Path -Path $gemfile ) {
    Write-Host ("Renaming unused gemfile.lock for http_parser 0.6.0")
    Rename-Item -Path $gemfileFullPath -NewName  "renamed_Gemfile_lock.renamed"
}