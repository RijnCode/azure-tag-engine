#! /usr/bin/env pwsh

<#
.SYNOPSIS
Sample plugin rule definition for using a previously set in-memory value

.DESCRIPTION
Sample plugin rule definition for using a previously set in-memory value

#>
[CmdletBinding(SupportsShouldProcess = $false)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType "Leaf" })]
    [string]$ExecutingFilePath
)
begin {
    $Script:scriptRuleName = (
        (Split-Path -Path $ExecutingFilePath -Leaf).
        Replace("Definition.ps1", "")
    )
    $Script:scriptRuleMetaName = "PluginFunctionMeta-${Script:scriptRuleName}"
    
    $Script:scriptRuleMeta = @{
        'rule_definition' = (Split-Path -Path $ExecutingFilePath -Leaf).Replace(".ps1", "")
        'RuleName'        = $Script:scriptRuleName
    }

    if ((Test-Path "variable:global:$( $Script:scriptRuleMetaName )") -eq $false) {
        New-Variable -Name $Script:scriptRuleMetaName -Value $Script:scriptRuleMeta -Option Constant -Scope Global -Force
    }
}
process {

    function global:Invoke-TagRuleUseSetValue {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [ValidateNotNullOrWhiteSpace()]
            [Parameter(Mandatory = $true)]
            [string]$InstanceName,
            [Parameter(Mandatory = $true)]
            [ValidateNotNull()]
            [PSCustomObject]$Inputs,
            [Parameter(Mandatory = $true)]
            [ref]$Tags,
            [Parameter(Mandatory = $true)]
            [int]$Indentation
        )

        if (-not ($Tags.Value -is [hashtable])) {
            throw "Tags must be a hashtable"
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Executing Rule"

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Values Get: $( $Global:RijnCodeTempValue | ConvertTo-Json -Compress -Depth 99 )"

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Execution Complete"
    }

}
end {

}
