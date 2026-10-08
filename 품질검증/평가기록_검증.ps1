param(
    [string]$ResultPath = (Join-Path $PSScriptRoot '독립_비교평가_결과.json')
)
$ErrorActionPreference = 'Stop'
$taskWorkspace = Split-Path -Parent $PSScriptRoot
$taskResult = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
$taskRuns = @($taskResult.runs)
if ($taskRuns.Count -ne 48) { throw "48개 독립 실행 기록이 필요합니다. 현재: $($taskRuns.Count)" }
$taskKeys = @{}
$taskProperties = @('body','argument','alignment','evidence','efficiency')
foreach ($taskRun in $taskRuns) {
    if ($taskRun.version -notin @('v1','v2')) { throw '알 수 없는 버전' }
    if ($taskRun.caseId -notmatch '^T(0[1-9]|1[0-2])$') { throw '알 수 없는 케이스' }
    if ($taskRun.repeat -notin @(1,2)) { throw '회차 오류' }
    $taskKey = "$($taskRun.version)_$($taskRun.caseId)_$($taskRun.repeat)"
    if ($taskKeys.ContainsKey($taskKey)) { throw "중복 실행: $taskKey" }
    $taskKeys[$taskKey] = $true
    $taskOutput = [string]$taskRun.outputFile
    if (-not [IO.Path]::IsPathRooted($taskOutput)) {
        $taskOutput = Join-Path $taskWorkspace $taskOutput
    }
    $taskResolved = [IO.Path]::GetFullPath($taskOutput)
    if (-not $taskResolved.StartsWith($taskWorkspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "workspace 밖 출력 경로: $taskKey"
    }
    if (-not (Test-Path -LiteralPath $taskResolved -PathType Leaf)) { throw "출력 누락: $taskKey" }
    if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $taskResolved -Raw))) { throw "빈 출력: $taskKey" }
    foreach ($taskProperty in $taskProperties) {
        if ($null -eq $taskRun.scores.PSObject.Properties[$taskProperty]) { throw "평가 항목 누락: $taskKey/$taskProperty" }
        $taskScore = $taskRun.scores.$taskProperty
        if ($null -ne $taskScore -and $taskScore -notin @(0,1,2,3)) { throw "점수 범위 오류: $taskKey/$taskProperty" }
    }
    if ($null -eq $taskRun.PSObject.Properties['criticalFailures']) { throw "필수 실패 판정 누락: $taskKey" }
    if (@($taskRun.evidence).Count -eq 0) { throw "판정 근거 누락: $taskKey" }
}
$taskImproved = @($taskRuns | Where-Object version -eq 'v2')
$taskCritical = @($taskImproved | Where-Object { @($_.criticalFailures).Count -gt 0 })
$taskLow = @($taskImproved | Where-Object {
    $taskCurrent = $_
    @($taskProperties | Where-Object { $null -ne $taskCurrent.scores.$_ -and $taskCurrent.scores.$_ -lt 2 }).Count -gt 0
})
$taskCore = @('T02','T06','T07','T08','T11')
$taskCoreMissing = @($taskImproved | Where-Object {
    $_.caseId -in $taskCore -and ($null -eq $_.scores.body -or $_.scores.body -lt 2)
})
$taskWritingCases = @('T02','T03','T04','T06','T07','T08','T09','T10','T11','T12')
$taskBefore = @($taskRuns | Where-Object { $_.version -eq 'v1' -and $_.caseId -in $taskWritingCases -and $null -ne $_.scores.body })
$taskAfter = @($taskRuns | Where-Object { $_.version -eq 'v2' -and $_.caseId -in $taskWritingCases -and $null -ne $_.scores.body })
$taskBeforeMean = ($taskBefore | ForEach-Object { $_.scores.body } | Measure-Object -Average).Average
$taskAfterMean = ($taskAfter | ForEach-Object { $_.scores.body } | Measure-Object -Average).Average
$taskRegressions = @()
foreach ($taskNew in $taskImproved) {
    $taskOld = $taskRuns | Where-Object { $_.version -eq 'v1' -and $_.caseId -eq $taskNew.caseId -and $_.repeat -eq $taskNew.repeat }
    foreach ($taskProperty in @('alignment','evidence')) {
        if ($null -ne $taskOld.scores.$taskProperty -and $null -ne $taskNew.scores.$taskProperty -and $taskNew.scores.$taskProperty -lt $taskOld.scores.$taskProperty) {
            $taskRegressions += "$($taskNew.caseId)/r$($taskNew.repeat)/$taskProperty"
        }
    }
}
[pscustomobject]@{
    RecordIntegrity = '48개 고유 기록과 실제 출력 파일·평가 근거 확인'
    V2CriticalFailures = $taskCritical.Count
    V2LowScoreRuns = $taskLow.Count
    V2CoreBodyFailures = $taskCoreMissing.Count
    BaselineBodyMean = $taskBeforeMean
    ImprovedBodyMean = $taskAfterMean
    PairedRegressions = $taskRegressions
    ScoreGatePassed = ($taskCritical.Count -eq 0 -and $taskLow.Count -eq 0 -and $taskCoreMissing.Count -eq 0 -and $taskAfterMean -ge $taskBeforeMean -and $taskRegressions.Count -eq 0)
    Limitation = '파일·판정 기록의 구조 검사입니다. 점수와 필수 실패 판단의 타당성은 실제 출력에 대한 검토가 필요합니다.'
} | ConvertTo-Json -Depth 5
