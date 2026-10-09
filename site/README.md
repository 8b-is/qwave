# Qwave product and support site

Static companion site for the current 2.0.4 TestFlight build. Product copy must stay aligned with the build available to users; newer translation/panel work is explicitly not advertised as shipped.

## Local preview

Run `python3 -m http.server 4186 --bind 127.0.0.1 --directory site` from the repository root. No Node dependencies, analytics, remote fonts, JavaScript, or client forms.

## Existing Hetzner / Coolify deployment

Intended hostname: `qwave.8b.is`. This hostname has not been provisioned. Reuse the existing server and HTTPS reverse proxy; do not replace existing sites or expose management services.

For a Coolify Dockerfile application use build context `site`, Dockerfile `Dockerfile`, container port `8080`, and an HTTPS domain `https://qwave.8b.is`. The Caddy listener is HTTP behind the existing TLS proxy. Validate and pin the official Caddy image digest during deployment. Alternatively serve only index.html, style.css, support/, and privacy/ from the existing static virtual host; apply the security headers in Caddyfile to that virtual host.

Before deployment, confirm the public support/privacy contact and the host logging configuration. The privacy notice is a factual source-based draft, not a completed App Store privacy questionnaire. Avoid promising a retention period until hosting behavior is verified.

After deployment check valid TLS and HTTP 200 for `/`, `/support/`, `/privacy/`, and `/style.css`; verify internal links and responsive layout. Then use those live URLs in App Store Connect. Keep the previous site files/config for rollback and change only the dedicated Qwave virtual host. No production changes have been performed by preparing this directory.
