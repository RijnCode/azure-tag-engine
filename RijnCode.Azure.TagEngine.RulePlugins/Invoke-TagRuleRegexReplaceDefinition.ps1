#! /usr/bin/env pwsh

<#
.SYNOPSIS
Sample plugin rule definition for performing a regex replace on a tag keys

.DESCRIPTION
Sample plugin rule definition for performing a regex replace on a tag keys

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

    function global:Invoke-TagRuleRegexReplace {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [ValidateNotNullOrWhiteSpace()]
            [Parameter(Mandatory = $true)]
            [string]$InstanceName,
            # [Parameter(Mandatory = $true)]
            # [ValidateNotNullOrWhiteSpace()]
            # [string]$SearchExactMatch,
            [Parameter(Mandatory = $true)]
            [ValidateNotNull()]
            [PSCustomObject]$Inputs,
            [Parameter(Mandatory = $true)]
            [ref]$Tags,
            [Parameter(Mandatory = $true)]
            [int]$Indentation,

            # Optional Defaults
            [Parameter(Mandatory = $false)]
            [Single]$MinimumScore = .99
        )

        if (-not ($Tags.Value -is [hashtable])) {
            throw "Tags must be a hashtable"
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Executing Rule"


        $keysMatchingSearch = @(
            $Tags.Value.Keys |
            Where-Object { $_ -match $Inputs.search_regex }
        )

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Rule Matches: $( $keysMatchingSearch.Count )"

        foreach ($keyToReplace in $keysMatchingSearch) {
            $newKey = $keyToReplace -replace $Inputs.search_regex, $Inputs.value_replacement
            $Tags.Value[$newKey] = $Tags.Value[$keyToReplace]
            $Tags.Value.Remove($keyToReplace)
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Post-Execution Tags: $( $Tags.Value | ConvertTo-Json -Compress -Depth 99 )"
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Execution Complete"
    }

}
end {

}
