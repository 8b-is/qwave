# Qwave product and support site

Static companion site for the current 2.0.4 TestFlight build. Product copy must stay aligned with the build available to users; newer translation/panel work is explicitly not advertised as shipped.

## Local preview

Run `python3 -m http.server 4186 --bind 127.0.0.1 --directory site` from the repository root. No Node dependencies, analytics, remote fonts, JavaScript, or client forms.

## Existing Hetzner / Coolify deployment

Live hostname: `https://qwave.8b.is`. The dedicated Coolify application uses the existing server and HTTPS reverse proxy. Existing wildcard DNS already covered this hostname; no new server or DNS record was needed. Do not replace other sites or expose management services.

For a Coolify Dockerfile application use build context `site`, Dockerfile `Dockerfile`, container port `8080`, and an HTTPS domain `https://qwave.8b.is`. The Caddy listener is HTTP behind the existing TLS proxy. The official Caddy image is pinned by digest in Dockerfile. Alternatively serve only index.html, style.css, support/, and privacy/ from the existing static virtual host; apply the security headers in Caddyfile to that virtual host.

The approved public support/privacy contact is c@8b.is. At the initial deployment, the inspected reverse proxy had no access-log option and configured external log drains were disabled. Caddyfile does not enable access logging. Recheck these settings before changing privacy claims. The privacy notice is a factual source-based draft, not a completed App Store privacy questionnaire. Avoid promising a retention period until hosting behavior is verified.

After deployment check valid TLS and HTTP 200 for `/`, `/support/`, `/privacy/`, and `/style.css`; verify internal links and responsive layout. Then use those live URLs in App Store Connect. Keep the previous site files/config for rollback and change only the dedicated Qwave virtual host. The initial production deployment used source commit `97a42ff01186417fcd29a3a83b8f8344d5d442bf`; all four served files matched their source hashes over valid HTTPS. Support and marketing URLs were saved for both Apple platforms, and the shared privacy URL was saved. This static deployment does not publish newer app features to TestFlight.
