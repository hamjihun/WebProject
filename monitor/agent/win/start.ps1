# 바탕화면 "IMS Monitoring Agent" 아이콘이 실행하는 스크립트
# 에이전트(작업 스케줄러)가 멈춰 있으면 시작하고, 트레이 아이콘을 띄웁니다.
Add-Type -AssemblyName System.Windows.Forms
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "IMSMonitoringAgent"

$out = & schtasks.exe /Query /TN $TaskName /FO CSV /NH 2>$null
if ($LASTEXITCODE -ne 0 -or -not $out) {
  [System.Windows.Forms.MessageBox]::Show("에이전트가 설치되어 있지 않습니다.`n설치 프로그램(IMS-Monitoring-Agent-Setup.exe)을 먼저 실행하세요.", "IMS Monitoring Agent") | Out-Null
  exit 1
}
$row = ($out | Select-Object -Last 1) | ConvertFrom-Csv -Header TaskName, NextRun, Status
if ($row.Status -notmatch 'Running|실행') {
  try { Start-Process -FilePath "schtasks.exe" -ArgumentList @('/Run', '/TN', $TaskName) -Verb RunAs -WindowStyle Hidden -Wait } catch {}
}
Start-Process -FilePath "wscript.exe" -ArgumentList "`"$Dir\tray.vbs`""
