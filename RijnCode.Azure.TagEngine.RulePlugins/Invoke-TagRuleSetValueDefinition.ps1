#! /usr/bin/env pwsh

<#
.SYNOPSIS
Sample plugin rule definition for setting a value in memory that can be used in other rules

.DESCRIPTION
Sample plugin rule definition for setting a value in memory that can be used in other rules

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

    function global:Invoke-TagRuleSetValue {
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

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable is used in Invoke-TagRuleUseSetValue rule')]
        $Global:RijnCodeTempValue = @{  
            'resource_id'      = $Inputs.resource_id
            'some_other_value' = $Inputs.value_to_set
        }

        # Dynamically default a statistic for each rule instance for custom TagEngine output at end of run
        $Global:TagEngineCustomStatistics = [ordered]@{}
        $ruleConfigContent = Get-Content -Path "${PSScriptRoot}/_TagRuleConfig.yml" | ConvertFrom-Yaml -Ordered -Verbose:$false
        $tempHashTable = [ordered]@{}
        $ruleConfigContent.rules_config.all_tags.GetEnumerator() | Sort-Object -Property order | ForEach-Object { $tempHashTable.Add($_.instance_name, 0) }
        foreach ($ruleAllTagsCategoryRule in @('Subscription', 'ResourceGroup', 'Resource', 'Total')) {
            $Global:TagEngineCustomStatistics[$ruleAllTagsCategoryRule] = $tempHashTable
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Values Set: 2"

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Execution Complete"
    }

}
end {

}
