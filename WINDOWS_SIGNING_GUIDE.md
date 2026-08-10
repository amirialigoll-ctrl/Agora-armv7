# Centralized Windows Code-Signing Guide

This repository contains the configuration and templates for centralized Windows code-signing.

## Architecture

We use a single self-signed identity for all Windows applications in the organization.
- **Identity**: Alireza Code Signing
- **EKU**: Code Signing (1.3.6.1.5.5.7.3.3)
- **Validity**: 10 years

## GitHub Secrets Setup

Since I do not have permission to manage secrets directly, you must manually add the following secrets to your GitHub Organization (or this repository if you don't have an organization yet):

1. **WINDOWS_SIGNING_CERTIFICATE_BASE64**: The Base64-encoded PFX certificate.
2. **WINDOWS_SIGNING_CERTIFICATE_PASSWORD**: The password for the PFX certificate.

> **Note**: These values are provided in the final report of this task. Please store them securely and do not share them.

## Using the Signing Identity in Workflows

Every Windows repository should include a step in its GitHub Actions workflow to sign the artifacts. A template workflow is provided in `.github/workflows/windows-signing-template.yml.example`.

### Key Steps in Workflow:

1. **Retrieve and Decode Certificate**:
   ```yaml
   - name: Import Windows Certificate
     shell: pwsh
     run: |
       $cert_base64 = "${{ secrets.WINDOWS_SIGNING_CERTIFICATE_BASE64 }}"
       $cert_bytes = [System.Convert]::FromBase64String($cert_base64)
       [System.IO.File]::WriteAllBytes("certificate.pfx", $cert_bytes)
   ```

2. **Sign Artifact**:
   ```yaml
   - name: Sign Executable
     shell: pwsh
     run: |
       & "C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe" sign /f certificate.pfx /p "${{ secrets.WINDOWS_SIGNING_CERTIFICATE_PASSWORD }}" /td sha256 /fd sha256 my-app.exe
   ```

3. **Cleanup**:
   ```yaml
   - name: Cleanup Certificate
     if: always()
     run: |
       Remove-Item -Path "certificate.pfx" -Force
   ```

## Security Best Practices

- **Never** commit `.pfx`, `.key`, or `.crt` files to the repository.
- **Never** print secret values in logs.
- **Always** use a temporary file for the certificate and delete it after signing.
- Ensure the `.gitignore` includes entries for signing material.
