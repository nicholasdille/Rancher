# Options: Info, Verbose, Debug
$LogLevelPreference = 'Debug'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message = ''
        ,
        [Parameter()]
        [ValidateSet('Info', 'Verbose', 'Debug', 'Warning', 'Error', 'Exception')]
        [string]
        $Level = 'Info'
        ,
        [Parameter()]
        [ValidateNotNull()]
        [string]
        $Indent = ''
    )

    $StackSize = (Get-PSCallStack).Length
    $Indent = '  ' * ($StackSize - 2)
    $StackItem = (Get-PSCallStack)[1]
    $Name = $StackItem.Command

    $MessageString = '{0}[{1}] {2}' -f $Indent, $Name, $Message

    switch ($Level) {
        'Output' {
            Write-Host -Object $MessageString
        }
        'Verbose' {
            if ($LogLevelPreference -and @('Verbose', 'Debug') -icontains $LogLevelPreference) {
                Write-Host -Object $MessageString -ForegroundColor Cyan
            }
        }
        'Debug' {
            if ($LogLevelPreference -and @('Debug') -icontains $LogLevelPreference) {
                Write-Host -Object $MessageString -ForegroundColor Yellow
            }
        }
        'Warning' {
            Write-Warning -Object $MessageString
        }
        'Error' {
            Write-Error -Object $MessageString
        }
        'Exception' {
            Write-Error -Object $MessageString
            throw
        }
    }
}

function Get-RancherToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl
        ,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ProjectId
        ,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $TokenName
        ,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [pscredential]
        $Credential = (Get-Credential)
    )

    Write-Log -Level Debug -Message 'Generate token name if parameter not specified'
    if (-Not $TokenName) {
        $Alphabet = @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f')
        $TokenName = ($Alphabet | Get-Random -Count 8) -join ''
        Write-Log -Level Debug -Message ('Using token name {0}' -f $TokenName)
    }

    Write-Log -Level Debug -Message 'Request token using project ID (i.e. an environment) and an name to identify the token'
    $RequestTokenResponseJson = Invoke-WebRequest -Uri "$BaseUrl/v1/projects/$ProjectId/registrationTokens" -Method Post -Headers @{'Content-Type' = 'application/json'; 'Accept' = 'application/json'} -Body "{`"name`": `"$TokenName`"}" -Credential $Credential -Verbose:$false
    $RequestTokenResponse = $RequestTokenResponseJson | Select-Object -ExpandProperty Content | ConvertFrom-Json
    Write-Log -Level Debug -Message 'Make sure the response references the token name'
    if ($RequestTokenResponse.name -ne $TokenName) {
        Write-Log -Level Exception -Message 'Response contains unknown token name'
    }
    Write-Log -Level Debug -Message 'Make sure the token is being registered'
    if ($RequestTokenResponse.state -ine 'registering') {
        Write-Log -Level Exception -Message 'Failed to register token'
    }
    Write-Log -Level Debug 'Token successfully requested'

    Write-Log -Level Debug 'Retrieve token using name from above'
    # The token may need some time to become active
    $TokenInProgress = $true
    while ($TokenInProgress) {
        Write-Log -Level Debug -Message 'Request list of tokens'
        $TokenResponseJson = Invoke-WebRequest -Uri "$BaseUrl/v1/registrationTokens" -Method Get -Headers @{'Accept' = 'application/json'} -Credential $Credential -Verbose:$false
        $TokenResponse = $TokenResponseJson| Select-Object -ExpandProperty Content | ConvertFrom-Json
        Write-Log -Level Debug -Message 'Extract token by name'
        $TokenData = $TokenResponse.data | Where-Object {$_.name -eq $TokenName}
        Write-Log -Level Debug -Message 'Check if token is already registered'
        $TokenInProgress = $TokenData.state -eq 'registering'
    }
    Write-Log -Level Debug -Message 'Extract token'
    Write-Log -Level Debug -Message $TokenData
    $Token = $TokenData | Select-Object -ExpandProperty token
    Write-Log -Level Debug 'Make sure the token is not empty'
    if ($Token.Length -eq 0) {
        Write-Log -Level Debug -Message $TokenData
        Write-Log -Level Exception -Message ('Unable to extract token for name {0}' -f $TokenName)
    }
    Write-Log -Level Verbose -Message ('Got token {0}' -f $Token)

    Write-Log -Level Debug -Message 'Return token'
    $Token
}

function Get-RancherMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl
        ,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ProjectId
        ,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [scriptblock]
        $Filter = {$true}
        ,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [pscredential]
        $Credential = (Get-Credential)
    )

    Write-Log -Level Verbose -Message 'Request hosts'
    $HostResponseJson = Invoke-WebRequest -Uri "$BaseUrl/v1/hosts" -Method Get -Headers @{'Accept' = 'application/json'} -Credential $Credential -Verbose:$false
    $HostResponse = $HostResponseJson | Select-Object -ExpandProperty Content | ConvertFrom-Json

    Write-Log -Level Verbose 'Filter and return hosts'
    $HostResponse.data | Where-Object -FilterScript $Filter
}

function Get-RancherMachineConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseUrl
        ,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('physicalHostId')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $HostId
        ,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('accountId')]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $ProjectId
        ,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path = (Get-Item -Path '~')
        ,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [pscredential]
        $Credential = (Get-Credential)
    )

    BEGIN {
        Write-Log -Level Verbose -Message 'Initializing token store'
        $Tokens = @{}
    }

    PROCESS {
        Write-Log -Level Verbose -Message 'Processing block'
        for ($i = 0; $i -lt $HostId.Length; ++$i) {
            $ThisHostId = $HostId[$i]
            $ThisProjectId = $ProjectId[$i]
            Write-Log -Level Verbose -Message ('Processing host {0} in project {1}' -f $ThisHostId, $ThisProjectId)

            Write-Log -Level Verbose -Message 'Make sure that a token exists'
            if (-Not $Tokens.ContainsKey($ThisProjectId)) {
                $Tokens[$ThisProjectId] = Get-RancherToken -BaseUrl $BaseUrl -ProjectId $ThisProjectId -Credential $Credential
            }

            Write-Log -Level Verbose -Message 'Download machine config'
            $ResponseJson = Invoke-WebRequest -Uri "$BaseUrl/v1/projects/$ThisProjectId/machines/$ThisHostId/config?token=$($Tokens[$ThisProjectId])&projectId=$ThisProjectId" -Method Get -Headers @{'Accept' = 'application/json'} -Credential $Cred -Verbose:$false
            $Response = $ResponseJson | Select-Object -ExpandProperty Content | ConvertFrom-Json
            
            Write-Log -Level Verbose -Message 'Extracting filename from header'
            If ($ResponseJson.Headers['Content-Disposition'] -match '\=(.+\.tar\.gz)$') {
                $FileName = $Matches[1]

            } else {
                Write-Log -Level Verbose -Message ('Unable to extract filename for host {0} from header ({1}). Using host ID.' -f $ThisHostId, $ResponseJson.Headers['Content-Disposition'])
                $FileName = "$ThisHostId.tar.gz"
            }
            Write-Log -Level Verbose -Message ('Using filename {0}' -f $FileName)

            Write-Log -Level Verbose -Message 'Writing machine config'
            [System.IO.File]::WriteAllBytes("$Path\$FileName", $ResponseJson.Content)
        }
    }
}