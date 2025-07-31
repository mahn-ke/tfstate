if (-not (Get-Location).Path -like '*-by-vincent*') {
    Write-Host "Repository does not contain '-by-vincent'. No subdomain is requested."
    exit 0
}



function Get-FirstHostPort {
    $composeFile = "docker-compose.yml"

    # Ensure powershell-yaml module is installed and imported
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    if (-not (Test-Path $composeFile)) {
        Write-Error "docker-compose.yml not found"
        exit 1
    }

    $type = ''  
    $firstLine = (Get-Content $composeFile -First 1).Trim()
    if ($firstLine -and $firstLine.StartsWith('#')) {
        $type = $firstLine.TrimStart('#').Trim()
    } else {
        $type = 'http'  # Default type if no comment is found
        Write-Warning "No type specified in the first line of docker-compose.yml, defaulting to 'http'."
    }
    $yaml = ConvertFrom-Yaml (Get-Content $composeFile -Raw)
    if (-not $yaml.services) {
        Write-Error "No 'services' section found in docker-compose.yml"
        exit 1
    }

    $portInfo = $null
    foreach ($service in $yaml.services.Values) {
        if (-not $service.ports) { 
            continue 
        }
        foreach ($port in $service.ports) {
            # Trim whitespace and match "hostPort:containerPort" or "ip:hostPort:containerPort"
            if ($port.Trim() -match '(\d+):\d+$') {
                $portInfo = @{
                    port = $matches[1]
                    type = $type
                }
                break
            }
        }
        if ($portInfo) { 
            break 
        }
    }

    return $portInfo
}

if (-not [System.Environment]::GetEnvironmentVariable("NGINX_HOME")) {
    Write-Error "Environment variable 'NGINX_HOME' is not set."
    exit 1
}

$firstPortInfo = Get-FirstHostPort

if (-not $firstPortInfo) {
    Write-Error "Could not find a host port in docker-compose.yml"
    exit 0
}

Write-Host "First host port found: $($firstPortInfo.port) of type '$($firstPortInfo.type)'"

# Step 1: Generate NGINX configuration
$proc = Start-Process -FilePath "pwsh" -ArgumentList "-File", "./tools/New-NginxConfig.ps1", "-type", $firstPortInfo.type, "-port", $firstPortInfo.port -Wait -PassThru
$exitCode = $proc.ExitCode
if ($exitCode -ne 0) {
    Write-Host "New-NginxConfig.ps1 failed with exit code $exitCode."
    exit $exitCode
}

# Step 2: Try to apply NGINX configuration
$proc = Start-Process -FilePath "pwsh" -ArgumentList "-File", "./tools/Update-NginxConfig.ps1", "-type", $firstPortInfo.type -Wait -PassThru
$exitCode = $proc.ExitCode
if ($exitCode -ne 0) {
    Write-Host "Update-NginxConfig.ps1 failed with exit code $exitCode."
    exit $exitCode
}

if ($firstPortInfo.type -ne 'http') {
    Write-Host "Port type is not 'http'; skipping HTTPS configuration."
    Write-Host "Deployment completed successfully."
    exit 0
}

if (-not [System.Environment]::GetEnvironmentVariable("CERT_HOME")) {
    Write-Error "Environment variable 'CERT_HOME' is not set."
    exit 1
}

# Step 3: Generate SSL certificates
$proc = Start-Process -FilePath "pwsh" -ArgumentList "-File", "./tools/New-Certificate.ps1" -Wait -PassThru
$exitCode = $proc.ExitCode
if ($exitCode -ne 0) {
    Write-Host "New-Certificate.ps1 failed with exit code $exitCode."
    exit $exitCode
}

# Step 4: Generate HTTP+HTTPS NGINX configuration
$proc = Start-Process -FilePath "pwsh" -ArgumentList "-File", "./tools/New-NginxConfig.ps1", "-type", "https", "-port", $firstPortInfo.port -Wait -PassThru
$exitCode = $proc.ExitCode
if ($exitCode -ne 0) {
    Write-Host "New-NginxConfig.ps1 -WithHttps failed with exit code $exitCode."
    exit $exitCode
}

# Step 5: Try to apply HTTP+HTTPS NGINX configuration
$proc = Start-Process -FilePath "pwsh" -ArgumentList "-File", "./tools/Update-NginxConfig.ps1", "-type", "https" -Wait -PassThru
$exitCode = $proc.ExitCode
if ($exitCode -ne 0) {
    Write-Host "Update-NginxConfig.ps1 (HTTPS) failed with exit code $exitCode."
    exit $exitCode
}

Write-Host "Deployment completed successfully."