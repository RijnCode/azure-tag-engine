#! /usr/bin/env pwsh

<#
.SYNOPSIS
Sample plugin rule definition for performing a fuzzy match and clone on a tag keys using RatcliffObershelp Similarity algorithm

.DESCRIPTION
Sample plugin rule definition for performing a fuzzy match and clone on a tag keys using RatcliffObershelp Similarity algorithm

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
        'RuleName' = $Script:scriptRuleName
    }

    if ((Test-Path "variable:global:$( $Script:scriptRuleMetaName )") -eq $false) {
        New-Variable -Name $Script:scriptRuleMetaName -Value $Script:scriptRuleMeta -Option Constant -Scope Global -Force
    }
}
process {

    function global:Invoke-TagRuleRatcliffObershelpMatchClone {
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
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Executing Rule"

        # Get base count for log stats
        $similiarityResults = @()
        $Tags.Value.Keys |
        ForEach-Object {
            $similiarityResults += @{ 'Result' = "$_"; 'Score' = (Get-RatcliffObershelpSimilarity -String1 $Inputs.required_tag_key -String2 $_ -Verbose:$false ) }
        }
        $highestScore = ($similiarityResults.Score | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum) ?? 0
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Highest Score: ${highestScore}"

        # Limit to one match for replacement
        $similiarityResults = @(
            $similiarityResults |
            Where-Object { $_.Result -cne $Inputs.required_tag_key } |
            Where-Object { $_.Result -notcontains " " } |
            Where-Object { $_.Score -ge $Inputs.minimum_score } |
            Where-Object { $_.Score -eq $highestScore } |
            Select-Object -First 1
        )

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Rule Matches: $( $similiarityResults.Count ?? 0 )"

        foreach ($singleMatchToReplace in $similiarityResults) {
            if ($Tags.Value.ContainsKey($Inputs.required_tag_key) -eq $true) {
                Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Skipping ${ExactMatch} as it already exists"
                continue;
            }

            $Tags.Value[$Inputs.required_tag_key] = $Tags.Value[$singleMatchToReplace.Result]
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Post-Execution Tags: $( $Tags.Value | ConvertTo-Json -Compress -Depth 99 )"
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation $Indentation -Message "$( $MyInvocation.MyCommand ) (${InstanceName}) - Execution Complete"
    }

}
end {

}
