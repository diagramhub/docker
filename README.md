# diagramHub Self-Hosted Docker Setup

## Overview

This repository contains a Docker Compose setup for self-hosting [diagramHub](https://diagramhub.app), an online diagramming tool. The setup includes services for the web frontend, API backend, and draw.io integration.

## Prerequisites

- Docker and Docker Compose installed on your server
- An Azure Entra ID tenant and application for authentication
- **Two domain names** for accessing the application and draw.io service, like `app.yourdomain.com` and `drawio.yourdomain.com` and the corresponding DNS records pointing to your server's IP address and SSL certificates configured.

> For testing purposes, you can use `localhost` and `drawio.localhost` as FQDNs, but for production use, proper domain names are required.

## Setup Instructions

### Setup Entra ID Application

1. Register a new application in your Azure Entra ID tenant:
   - Name the application (e.g., "diagramHub Self-Hosted")
   - Select **Accounts in this organizational directory only**.
   - Set Platform to **Single-page Application**.
   - Configure the redirect URI to include:
     - `<APP_SCHEME>://<APP_FQDN>` (e.g. `http://localhost` or `https://app.yourdomain.com`)
   - Under **Expose an API**:
     - Set the **Aplication ID URI** to `api://<CLIENT_ID>`
     - Add a scope named `user_impersonation`.
2. Note down the **Tenant ID** and **Client ID** for later use.

> You can use the provided Bash/PowerShell script to automate the Entra ID app setup: `scripts/setup-entra-id-app.sh` or `scripts/setup-entra-id-app.ps1`.

### Deploying diagramHub with Docker Compose

1. Clone this repository to your server:

   ```bash
   git clone https://github.com/diagramhub/docker.git diagramhub-docker
   ```

2. Navigate to the project directory:

   ```bash
   cd diagramhub-docker
   ```

3. Create a `.env` file based on the provided `example.env`:

   ```bash
   cp example.env .env
   ```

4. Edit the `.env` file to set your **Azure Entra Tenant ID**, **Azure Entra Client ID**, and optionally the FQDNs for the app and draw.io services.

5. Start the Docker Compose services:

   ```bash
   docker-compose up -d
   ```

6. Access the application via your web browser at `<APP_SCHEME>://<APP_FQDN>` (e.g. `http://localhost`).

## License

You can use diagramHub Self-Hosted for free for personal use and evaluation/testing. It includes a free license for up to 3 users in the `example.env` file.

For **commercial use**, please acquire a license from [diagramHub contact](https://diagramhub.app/web/contact).
