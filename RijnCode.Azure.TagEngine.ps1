#!/usr/bin/env pwsh

<#
.SYNOPSIS
Rule Engine for applying tags to Azure resources

.DESCRIPTION
Rule Engine for applying tags to Azure resources

.EXAMPLE
RijnCode.Azure.TagEngine.ps1 -RequiredTagKeys @("key1", "key2") -Scopes @("Subscription") -TenantId "00000000-0000-0000-0000-000000000000" -SubscriptionIdFilters @("00000000-0000-0000-0000-000000000000")
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("Subscription", "ResourceGroup", "Resource")]
    [string[]]$Scopes,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -Path $_ -PathType "Container" })]
    [string]$RulePluginPath = "${PSScriptRoot}\$( [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Path $PSCommandPath -Leaf)) ).RulePlugins",
    [Parameter(Mandatory = $false)]
    [ValidatePattern("Invoke-*")]
    [string]$RulePluginFunctionNameFormat = "Invoke-TagRule*",
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$RulePluginMetadataVariableNameFormat = "PluginFunctionMeta-*",

    [Parameter(Mandatory = $false)]
    [string]$ScriptConfigPath = "${PSScriptRoot}\$( [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Path $PSCommandPath -Leaf)) ).config.yml",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", "InheritSwitch")]
    [string]$ConsoleLogLevel = "InheritSwitch",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Debug", "Verbose", "Info", "Warn", "Error", "InheritConsole")]
    [string]$LogFileLevel = "InheritConsole",
    [Parameter(Mandatory = $false)]
    [string]$LogFilePath = "${PSScriptRoot}\$( Split-Path -Path $PSCommandPath -Leaf ).log",

    [Parameter(Mandatory = $false)]
    [switch]$DisableLogIndentation,
    [Parameter(Mandatory = $false)]
    [switch]$SimulateResults
)
begin {
    # ############################## Script Settings ##############################
    $ErrorActionPreference = "Stop"
    $VerbosePreference = "Continue"
    Set-StrictMode -Version "Latest"

    # ############################## Script Requirements ##############################
    
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Error "This script requires PowerShell version 7 or higher."
        exit 1
    }

    # Explicit import to suppress  module writing verbose messages to output stream
    Import-Module -Name "powershell-yaml" -Verbose:$false *>$null
    Import-Module -Name "Az.Accounts", "Az.Resources" -Verbose:$false *>$null

    # ############################## Constants ##############################
    enum AllLogLevels {
        Error = 0
        Warn = 1
        Info = 2
        Verbose = 3
        Debug = 4
    }

    # ############################## Variable Defaults ##############################
    New-Variable -Name 'scriptBoundParameters' -Value $PSBoundParameters -Scope Script -Option ReadOnly -Force

    [AllLogLevels]$Script:maximumLogConsoleLevel = [AllLogLevels]::Info
    [AllLogLevels]$Script:maximumLogFileLevel = [AllLogLevels]::Info
    $Script:processedSubscriptions = @()
    $Script:processedResourceGroups = @()
    $Script:processedResources = @()

    # ############################## Function Definitions ##############################
    function global:Write-LogHeader {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [AllLogLevels]$LogLevel,
            [Parameter(Mandatory = $false)]
            [int]$Indentation = 0,
            [Parameter(Mandatory = $true)]
            [string]$Header,
            [Parameter(Mandatory = $false)]
            [boolean]$OutputConsole = $true,
            [Parameter(Mandatory = $false)]
            [ConsoleColor]$ConsoleColor = "White"
        )
        $IndentationSpaces = "    " * $Indentation * (-not $DisableLogIndentation)
        $formattedMessage = @(
            #"${IndentationSpaces}--------------------------------------------------"
            "`n"
            "${IndentationSpaces}${Header}"
            "${IndentationSpaces}--------------------------------------------------"
        ) -join "`n"


        if ($Script:maximumLogFileLevel -ge $LogLevel) {
            Add-Content -Path $LogFilePath -Value $formattedMessage
        }

        if (($OutputConsole) -and ($Script:maximumLogConsoleLevel -ge $LogLevel)) {
            Write-Host $formattedMessage -ForegroundColor $ConsoleColor
        }
    }

    function global:Write-LogMessage {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [AllLogLevels]$LogLevel,
            [Parameter(Mandatory = $false)]
            [int]$Indentation = 0,
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [Parameter(Mandatory = $false)]
            [boolean]$OutputConsole = $true,
            [Parameter(Mandatory = $false)]
            [ConsoleColor]$ConsoleColor = "White"
        )
        $IndentationSpaces = "    " * $Indentation * (-not $DisableLogIndentation)
        $formattedDate = (Get-Date).ToUniversalTime().ToString("o")

        if ($Script:maximumLogFileLevel -ge $LogLevel) {
            Add-Content -Path $LogFilePath -Value "${IndentationSpaces}[${formattedDate}] [${LogLevel}] ${Message}"
        }

        if (($OutputConsole) -and ($Script:maximumLogConsoleLevel -ge $LogLevel)) {
            Write-Host "${IndentationSpaces}[${formattedDate}] [${LogLevel}] ${Message}" -ForegroundColor $ConsoleColor
        }
    }

    function Initialize-Logging {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$LogFilePath,
            [Parameter(Mandatory = $false)]
            [boolean]$Append = $false
        )

        # # Set the log level for the console
        if (($ConsoleLogLevel -eq "InheritSwitch") -and ($scriptBoundParameters.ContainsKey('Debug') -eq $true)) {
            [AllLogLevels]$Script:maximumLogConsoleLevel = [AllLogLevels]::Debug
        }
        elseif (($ConsoleLogLevel -eq "InheritSwitch") -and ($scriptBoundParameters.ContainsKey('Verbose') -eq $true)) {
            [AllLogLevels]$Script:maximumLogConsoleLevel = [AllLogLevels]::Verbose
        }
        else {
            [AllLogLevels]$Script:maximumLogConsoleLevel = [Enum]::Parse([AllLogLevels], $ConsoleLogLevel)
        }

        # Set the log level for the log file
        if ($LogFileLevel -eq "InheritConsole") {
            [AllLogLevels]$Script:maximumLogFileLevel = $Script:maximumLogConsoleLevel
        }
        else {
            [AllLogLevels]$Script:maximumLogFileLevel = [Enum]::Parse([AllLogLevels], $LogFileLevel)
        }

        # Initialize the log file
        if ((Test-Path $LogFilePath) -eq $false) {
            New-Item -Path $LogFilePath -ItemType "File" -Force | Out-Null
        }
        if ($Append -eq $false) {
            Clear-Content $LogFilePath
        }

        # Add entry header for log consistency
        Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Entering Begin Block" -ConsoleColor "Magenta"

        # Inform the user of selected settings
        Write-LogHeader -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Header "Logging Initialization" -ConsoleColor "Green"
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Console Output Log Level: $( $Script:maximumLogConsoleLevel )" -ConsoleColor "White"
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Log File Log Level: $( $Script:maximumLogFileLevel )" -ConsoleColor "White"
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Log file initialized" -ConsoleColor "White"
    }

    function Initialize-ScriptSettings {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$ConfigPath
        )
        Write-LogHeader -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Header "Initializing Script Settings" -ConsoleColor "Green"

        $tempConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Yaml -Ordered -Verbose:$false
        $schemaFilePath = "${PSScriptRoot}\TagEngine.config.schema.json"
        Test-Json -Json ($tempConfig | ConvertTo-Yaml -JsonCompatible -Verbose:$false) -SchemaFile $schemaFilePath -Options "IgnoreComments", "AllowTrailingCommas"

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Script Settings Loaded ($( $ConfigPath ))" -ConsoleColor "White"

        $Script:scriptConfig = $tempConfig
    }

    function Import-RulePluginDefinitionsToSession {
        [CmdletBinding(SupportsShouldProcess = $false)]
        [OutputType([hashtable])]
        param (
            [string]$RulePluginPath
        )

        Write-LogHeader -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Header "Importing Rule Plugin Definitions"

        if (-Not (Test-Path -PathType "Container" -Path $RulePluginPath)) {
            Write-LogMessage -LogLevel "$( [AllLogLevels]::Warn )" -Indentation 1 -Message "Rule plugin path is not valid: ${RulePluginPath}"
            return;
        }

        $PluginScripts = @(Get-ChildItem -Path "${RulePluginPath}" -Filter "${RulePluginFunctionNameFormat}Definition.ps1")

        if ($PluginScripts.Count -eq 0) {
            Write-LogMessage -LogLevel "$( [AllLogLevels]::Warn )" -Indentation 1 -Message "No valid rule plugins found in path: ${RulePluginPath}"
            return;
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Found $( $PluginScripts.Count ) rule plugin definitions on path: ${RulePluginPath}"

        foreach ($Script in $PluginScripts) {
            # Load content in-session and pass file path because it is not available in the child script scope
            & "$( $Script.FullName )" -ExecutingFilePath "$( $Script.FullName )"

            Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 1 -Message "Rule Plugin Definition Loaded: $( $Script.Name )"
        }

        $rawRuleDefinitions = Get-Variable -Name $RulePluginMetadataVariableNameFormat
        $importedRuleDefinitions = $rawRuleDefinitions

        return $importedRuleDefinitions
    }

    function Import-RulePluginConfigurationToSession {
        [CmdletBinding(SupportsShouldProcess = $false)]
        [OutputType([hashtable])]
        param (
            [string]$RulePluginPath
        )

        Write-LogHeader -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Header "Importing Rule Plugin Configuration"

        $rulePluginConfigPath = "${RulePluginPath}/_TagRuleConfig.yml"
        if (-Not (Test-Path -PathType "Leaf" -Path $rulePluginConfigPath)) {
            Write-LogMessage -LogLevel "$( [AllLogLevels]::Warn )" -Indentation 1 -Message "Rule plugin config path is not valid: ${rulePluginConfigPath}"
            return;
        }

        $rawRuleConfig = Get-Content -Path $rulePluginConfigPath | ConvertFrom-Yaml -Ordered -Verbose:$false
        $ruleConfig = $rawRuleConfig
        return $ruleConfig
    }

    function Get-InScopeSubscriptionIds {
        [CmdletBinding(SupportsShouldProcess = $false)]
        [OutputType([array])]
        param (
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]]$Filters
        )
        $returnSubscriptions = @()
        $rawSubscriptions = @()

        if (($scriptBoundParameters.ContainsKey('SimulateResults') -eq $true) -and ($Filters.Count -eq 0)) {
            $rawSubscriptions += $Script:scriptConfig.tag_engine_config.simulated_results.in_scope_subscription_ids.id
        }
        elseif ($scriptBoundParameters.ContainsKey('SimulateResults') -eq $true) {
            $rawSubscriptions += $Script:scriptConfig.tag_engine_config.processing_filters.subscription_id_filter
        }
        else {
            $rawSubscriptions = Get-AzSubscription -TenantId $TenantId |
            Where-Object { $_.State -eq "Enabled" }
        }

        $rawSubscriptions |
        Where-Object { ($Filters.Count -eq 0) -or ($Filters -contains $_) -or ($Filters -contains $_) } |
        ForEach-Object { $returnSubscriptions += $_ }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 0 -Message "subscriptionIdsInScope: $( $returnSubscriptions -join ", " )"

        return [array]$returnSubscriptions
    }

    function Get-CloudSubscriptionResourceTags {
        param (
            [Parameter(Mandatory = $true)]
            [string]$ResourceId
        )

        if ($scriptBoundParameters.ContainsKey('SimulateResults') -eq $true) {
            return @{' SimpleKey1' = 'SimpleKey1'; ' Complex TagKey3 ' = ' Complex TagKey3 '; 'Complex TagKey4' = 'Complex TagKey4'; 'simple key 5' = 'simple key 5'; 'SimplKey6' = 'SimplKey6' }
        }

        $resourceTagHashTable = @{}
        $rawTags = (Get-AzTag -ResourceId $ResourceId)
        foreach ( $tagKey in ($rawTags.Properties.TagsProperty.Keys ?? @()) ) {
            $resourceTagHashTable[$tagKey] = $rawTags.Properties.TagsProperty[$tagKey]
        }

        return $resourceTagHashTable
    }

    function Update-CloudResourceTags {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$ResourceId,
            [Parameter(Mandatory = $true)]
            [hashtable]$Tags,
            [Parameter(Mandatory = $false)]
            [int]$Indentation = 0
        )

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation $Indentation -Message "Updating Tags - Resource: $( $ResourceId ) / Tags: $( $Tags | ConvertTo-Json -Compress -Depth 99 )"

        if ($PSCmdlet.ShouldProcess($ResourceId)) {

        }
    }

    function Invoke-SubscriptionTagCleanOrchestrator {
        <#
        .SYNOPSIS
        Iterate subscription tags and applies a set of rules to update them.

        .NOTES
        Subscriptions are not affected by policy, so tags can be updated independently.

        #>
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SubscriptionId
        )

        $existingSubscriptionTags = Get-CloudSubscriptionResourceTags -ResourceId "/subscriptions/${SubscriptionId}"

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation 1 -Message "Original Subscription Tags: $( $existingSubscriptionTags | ConvertTo-Json -Compress -Depth 99 )"

        $updatedSubscriptionTags = @{}
        $updatedSubscriptionTags += $existingSubscriptionTags
        $updatedSubscriptionTagsRef = [ref]$updatedSubscriptionTags

        # All Tag Rules
        foreach ($ruleAllTagsCategoryRule in ($Script:scriptRulePluginConfig["rules_config"]["all_tags"] | Sort-Object -Property order, instance_name)) {
            $executeRuleDefinition = $Script:scriptRulePluginDefinitions.Value | Where-Object { $_.rule_definition -eq $ruleAllTagsCategoryRule.rule_definition }
            Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 1 -Message "Calling Plugin Rule: $( $executeRuleDefinition.RuleName ) ($( $ruleAllTagsCategoryRule.instance_name ))"

            $currentRuleFunctionName = $($executeRuleDefinition.RuleName)
            $ruleCommand = Get-Command -CommandType "Function" -Name $currentRuleFunctionName
            if ($null -eq $ruleCommand) {
                Write-LogMessage -LogLevel "$( [AllLogLevels]::Error )" -Indentation 1 -Message "Plugin Rule Call Failed: $( $executeRuleDefinition.RuleName )"
                throw "Rule Invoke Failed: $( $executeRuleDefinition.RuleName )"
            }

            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable is used in Invoke-Expression')]
            $currentRuleParams = @{
                'InstanceName' = $ruleAllTagsCategoryRule.instance_name
                'Inputs'       = $ruleAllTagsCategoryRule.inputs
                'Tags'         = $updatedSubscriptionTagsRef
                'Indentation'  = 1
            }

            Invoke-Expression "$currentRuleFunctionName @currentRuleParams" -Verbose:$false # Disable verbose to hide function reload warning
        }

        # Required Dynamic Tag Rules
        foreach ($currentRequiredTagKey in $Script:scriptConfig.tag_engine_config.required_tag_keys) {
            foreach ($ruleSubscriptionRequiredCategoryRule in ($Script:scriptRulePluginConfig["rules_config"]["subscription_required"] | Sort-Object -Property order, instance_name)) {
                $executeRuleDefinition = $Script:scriptRulePluginDefinitions.Value | Where-Object { $_.rule_definition -eq $ruleSubscriptionRequiredCategoryRule.rule_definition }
                Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 1 -Message "Calling Plugin Rule: $( $executeRuleDefinition.RuleName ) ($( $ruleSubscriptionRequiredCategoryRule.instance_name ) - ${currentRequiredTagKey})"

                $currentRuleFunctionName = $($executeRuleDefinition.RuleName)
                $ruleCommand = Get-Command -CommandType "Function" -Name $currentRuleFunctionName
                if ($null -eq $ruleCommand) {
                    Write-LogMessage -LogLevel "$( [AllLogLevels]::Error )" -Indentation 1 -Message "Plugin Rule Call Failed: $( $executeRuleDefinition.RuleName )"
                    throw "Rule Invoke Failed: $( $executeRuleDefinition.RuleName )"
                }

                $ruleSubscriptionRequiredCategoryRule.inputs['required_tag_key'] = $currentRequiredTagKey

                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable is used in Invoke-Expression')]
                $currentRuleParams = @{
                    'InstanceName' = $ruleSubscriptionRequiredCategoryRule.instance_name
                    'Inputs'       = $ruleSubscriptionRequiredCategoryRule.inputs
                    'Tags'         = $updatedSubscriptionTagsRef
                    'Indentation'  = 1
                }

                Invoke-Expression "$currentRuleFunctionName @currentRuleParams" -Verbose:$false # Disable verbose to hide function reload warning

                $ruleSubscriptionRequiredCategoryRule.inputs.Remove('required_tag_key')
            }
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation 1 -Message "Final Subscription Tags: $( $updatedSubscriptionTags | ConvertTo-Json -Compress -Depth 99 )"
        Update-CloudResourceTags -ResourceId $SubscriptionId -Tags $updatedSubscriptionTags -Indentation 1

        $Script:processedSubscriptions += $SubscriptionId
    }

    function Get-InScopeResourceGroups {
        [CmdletBinding(SupportsShouldProcess = $false)]
        [OutputType([array])]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SubscriptionId,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]]$Filters
        )
        $resourceGroupsInScope = @()
        $rawResourceGroups = @()

        if (($scriptBoundParameters.ContainsKey('SimulateResults') -eq $true) -and ($Filters.Count -eq 0)) {
            $rawResourceGroups += $Script:scriptConfig.tag_engine_config.simulated_results.in_scope_resource_groups.name
        }
        elseif ($scriptBoundParameters.ContainsKey('SimulateResults') -eq $true) {
            $rawResourceGroups += $Script:scriptConfig.tag_engine_config.processing_filters.resource_group_filter
        }
        else {
            $rawResourceGroups = @((Get-AzResourceGroup).ResourceGroupName)
        }

        $rawResourceGroups |
        Where-Object { ($Filters.Count -eq 0) -or ($Filters -contains $_) -or ($Filters -contains $_) } |
        ForEach-Object { $resourceGroupsInScope += $_ }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 1 -Message "ResourceGroupsInScope: $( $resourceGroupsInScope -join ", " )"

        return [array]$resourceGroupsInScope
    }

    function Invoke-ResourceGroupTagCleanOrchestrator {
        <#
        .SYNOPSIS
        Iterate subscription tags and applies a set of rules to update them.

        .NOTES
        Subscriptions are not affected by policy, so tags can be updated independently.

        #>
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SubscriptionId,
            [Parameter(Mandatory = $true)]
            [string]$ResourceGroup
        )

        $resourceGroupId = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroup}"

        $existingResourceGroupTags = Get-CloudSubscriptionResourceTags -ResourceId $resourceGroupId

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation 2 -Message "Original Resource Group Tags: $( $existingResourceGroupTags | ConvertTo-Json -Compress -Depth 99 )"

        $updatedResourceGroupTags = @{}
        $updatedResourceGroupTags += $existingResourceGroupTags
        $updatedResourceGroupTagsRef = [ref]$updatedResourceGroupTags

        # All Tag Rules
        foreach ($ruleAllTagsCategoryRule in ($Script:scriptRulePluginConfig["rules_config"]["all_tags"] | Sort-Object -Property order, instance_name)) {
            $executeRuleDefinition = $Script:scriptRulePluginDefinitions.Value | Where-Object { $_.rule_definition -eq $ruleAllTagsCategoryRule.rule_definition }
            Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 2 -Message "Calling Plugin Rule: $( $executeRuleDefinition.RuleName ) ($( $ruleAllTagsCategoryRule.instance_name ))"

            $currentRuleFunctionName = $($executeRuleDefinition.RuleName)
            $ruleCommand = Get-Command -CommandType "Function" -Name $currentRuleFunctionName
            if ($null -eq $ruleCommand) {
                Write-LogMessage -LogLevel "$( [AllLogLevels]::Error )" -Indentation 2 -Message "Plugin Rule Call Failed: $( $executeRuleDefinition.RuleName )"
                throw "Rule Invoke Failed: $( $executeRuleDefinition.RuleName )"
            }

            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable is used in Invoke-Expression')]
            $currentRuleParams = @{
                'InstanceName' = $ruleAllTagsCategoryRule.instance_name
                'Inputs'       = $ruleAllTagsCategoryRule.inputs
                'Tags'         = $updatedResourceGroupTagsRef
                'Indentation'  = 2
            }

            Invoke-Expression "$currentRuleFunctionName @currentRuleParams" -Verbose:$false # Disable verbose to hide function reload warning
        }

        # Required Dynamic Tag Rules
        foreach ($currentRequiredTagKey in $Script:scriptConfig.tag_engine_config.required_tag_keys) {
            foreach ($ruleSubscriptionRequiredCategoryRule in ($Script:scriptRulePluginConfig["rules_config"]["resource_group_required"] | Sort-Object -Property order, instance_name)) {
                $executeRuleDefinition = $Script:scriptRulePluginDefinitions.Value | Where-Object { $_.rule_definition -eq $ruleSubscriptionRequiredCategoryRule.rule_definition }
                Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 2 -Message "Calling Plugin Rule: $( $executeRuleDefinition.RuleName ) ($( $ruleSubscriptionRequiredCategoryRule.instance_name ) - ${currentRequiredTagKey})"

                $currentRuleFunctionName = $($executeRuleDefinition.RuleName)
                $ruleCommand = Get-Command -CommandType "Function" -Name $currentRuleFunctionName
                if ($null -eq $ruleCommand) {
                    Write-LogMessage -LogLevel "$( [AllLogLevels]::Error )" -Indentation 2 -Message "Plugin Rule Call Failed: $( $executeRuleDefinition.RuleName )"
                    throw "Rule Invoke Failed: $( $executeRuleDefinition.RuleName )"
                }

                $ruleSubscriptionRequiredCategoryRule.inputs['required_tag_key'] = $currentRequiredTagKey

                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable is used in Invoke-Expression')]
                $currentRuleParams = @{
                    'InstanceName' = $ruleSubscriptionRequiredCategoryRule.instance_name
                    'Inputs'       = $ruleSubscriptionRequiredCategoryRule.inputs
                    'Tags'         = $updatedResourceGroupTagsRef
                    'Indentation'  = 2
                }

                Invoke-Expression "$currentRuleFunctionName @currentRuleParams" -Verbose:$false # Disable verbose to hide function reload warning

                $ruleSubscriptionRequiredCategoryRule.inputs.Remove('required_tag_key')
            }
        }

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation 2 -Message "Final Resource Group Tags: $( $updatedResourceGroupTags | ConvertTo-Json -Compress -Depth 99 )"
        Update-CloudResourceTags -ResourceId $resourceGroupId -Tags $updatedResourceGroupTags -Indentation 2

        $Script:processedResourceGroups += $resourceGroupId
    }

    function Get-InScopeResources {
        [CmdletBinding(SupportsShouldProcess = $false)]
        [OutputType([array])]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SubscriptionId,
            [Parameter(Mandatory = $true)]
            [string]$ResourceGroup,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]]$Filters
        )
        $resourcesInScope = @()

        # ToDo...
        Write-LogMessage -LogLevel "$( [AllLogLevels]::Warn )" -Indentation 2 -Message "Get-InScopeResources not implemented" -ConsoleColor "Yellow"

        Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 2 -Message "ResourcesInScope: $( $resourcesInScope -join ", " )"

        return [array]$resourcesInScope
    }

    function Invoke-ResourceTagCleanOrchestrator {
        [CmdletBinding(SupportsShouldProcess = $false)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$SubscriptionId
        )
    }


    # ############################## Script Initialization ##############################
    Initialize-Logging -LogFilePath $LogFilePath
    Initialize-ScriptSettings -ConfigPath $ScriptConfigPath

    $pluginDefinitions = Import-RulePluginDefinitionsToSession -RulePluginPath $RulePluginPath
    $pluginConfig = Import-RulePluginConfigurationToSession -RulePluginPath $RulePluginPath

    New-Variable -Name 'scriptRulePluginDefinitions' -Value $pluginDefinitions -Scope Script -Option ReadOnly -Force
    New-Variable -Name 'scriptRulePluginConfig' -Value $pluginConfig -Scope Script -Option ReadOnly -Force

    Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Loading Rule Plugin Configuration (_TagRuleConfig.yml)..."
    
    $ruleConfigCount = 0
    foreach ($currentRuleCategory in $Script:scriptRulePluginConfig["rules_config"].Keys) {
        foreach ($currentRuleInstance in $Script:scriptRulePluginConfig["rules_config"]["${currentRuleCategory}"]) {
            $ruleConfigCount += 1
            Write-LogMessage -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 1 -Message "Category: ${currentRuleCategory} / Instance: $($currentRuleInstance.instance_name) / Definition: $($currentRuleInstance.rule_definition) / Order: $($currentRuleInstance.order)"
        }
    }

    Write-LogMessage -LogLevel "$( [AllLogLevels]::Info )" -Indentation 1 -Message "Loaded $( $ruleConfigCount ) rule plugin configurations"

    Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Exiting Begin Block" -ConsoleColor "Magenta"
}
process {
    # ############################## Main Script Orchestration ##############################
    Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Entering Process Block" -ConsoleColor "Magenta"

    $subscriptionIdsInScope = Get-InScopeSubscriptionIds -Filters $script:scriptConfig.tag_engine_config.processing_filters.subscription_id_filter
    foreach ($currentSubscriptionId in $subscriptionIdsInScope) {
        
        Write-LogHeader -LogLevel "$( [AllLogLevels]::Error )" -Indentation 1 -Header "Processing Subscription: /subscriptions/${currentSubscriptionId}" -ConsoleColor "Green"
        if ("Subscription" -in $Scopes) {
            if ($Script:processedSubscriptions -contains $currentSubscriptionId) {
                Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Indentation 1 -Header "Skipping duplicate subscription: /subscriptions/${currentSubscriptionId}" -ConsoleColor "Magenta"
                continue;
            }

            Invoke-SubscriptionTagCleanOrchestrator -SubscriptionId $currentSubscriptionId
        }

        $resourceGroupsinScope = Get-InScopeResourceGroups -SubscriptionId $currentSubscriptionId -Filters $script:scriptConfig.tag_engine_config.processing_filters.resource_group_filter
        foreach ($currentResourceGroup in $resourceGroupsinScope) {
            $currentResourceGroupId = "/subscriptions/${currentSubscriptionId}/resourceGroups/${currentResourceGroup}"
            
            if ($Script:processedResourceGroups -contains $currentResourceGroupId) {
                Write-LogHeader -LogLevel "$( [AllLogLevels]::Verbose )" -Indentation 1 -Header "Skipping duplicate resource group: ${currentResourceGroupId}" -ConsoleColor "Magenta"
                continue;
            }
            Write-LogHeader -LogLevel "$( [AllLogLevels]::Error )" -Indentation 2 -Header "Processing ResourceGroup: ${currentResourceGroupId}" -ConsoleColor "Green"
            
            if ("ResourceGroup" -in $Scopes) {
                Invoke-ResourceGroupTagCleanOrchestrator -SubscriptionId $currentSubscriptionId -ResourceGroup $currentResourceGroup
            }

            $resourcesInScope = Get-InScopeResources -SubscriptionId $currentSubscriptionId -ResourceGroup $currentResourceGroup -Filters $script:scriptConfig.tag_engine_config.processing_filters.resource_id_filter
            
            foreach ($currentResource in $resourcesInScope) {
                if ($Script:processedResources -contains $currentResourceGroupId) {
                    Write-LogHeader -LogLevel "$( [AllLogLevels]::Verbose )" -Header "Skipping duplicate resource group: ${currentResourceGroupId}" -ConsoleColor "Magenta"
                    continue;
                }

                if ("Resource" -in $Scopes) {
                    Invoke-ResourceTagCleanOrchestrator -SubscriptionId $currentSubscriptionId -ResourceGroup $currentResourceGroup -Resource $currentResource
                }
            
                Write-LogHeader -LogLevel "$( [AllLogLevels]::Error )" -Indentation 3 -Header "Resource Processed: ${currentResource}" -ConsoleColor "Green"    
            }

            Write-LogHeader -LogLevel "$( [AllLogLevels]::Error )" -Indentation 2 -Header "Resource Group Processed: ${currentResourceGroupId}" -ConsoleColor "Green"
        }

        Write-LogHeader -LogLevel "$( [AllLogLevels]::Error )" -Indentation 1 -Header "Subscription Processed: /subscriptions/${currentSubscriptionId}" -ConsoleColor "Green"
    }

    Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Exiting Process Block" -ConsoleColor "Magenta"
}
end {
    # Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Entering End Block" -ConsoleColor "Magenta"
    # Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Exiting End Block" -ConsoleColor "Magenta"
}
clean {
    # Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Entering Clean Block" -ConsoleColor "Magenta"
    # Write-LogHeader -LogLevel "$( [AllLogLevels]::Debug )" -Header "Exiting Clean Block" -ConsoleColor "Magenta"
}
