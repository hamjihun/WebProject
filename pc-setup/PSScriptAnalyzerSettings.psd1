# VS Code PowerShell 확장 / Invoke-ScriptAnalyzer 가 사용하는 규칙 설정
# 이 프로젝트 특성상 경고가 많이 나오지만 의도된 것들은 제외
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                        # 사용 안 함 (로그는 Write-Log)
        'PSUseApprovedVerbs',                           # Apply-ResumeState 등 이름 그대로 사용
        'PSUseShouldProcessForStateChangingFunctions',  # 도구 전체가 시스템 설정 변경용
        'PSUseSingularNouns',                           # Install-Programs 등
        'PSAvoidGlobalVars',
        'PSUseDeclaredVarsMoreThanAssignments',         # 런스페이스/이벤트 스크립트블록에서 쓰는 변수를 잘못 잡음
        'PSReviewUnusedParameter',                      # WinForms 이벤트 param($s, $e)
        'PSAvoidUsingEmptyCatchBlock',                  # UI 자동화는 실패해도 계속 진행이 의도
        'PSUseBOMForUnicodeEncodedFile'                 # 파일은 BOM 으로 저장됨 (.editorconfig)
    )
}
