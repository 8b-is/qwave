FROM caddy:2-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f
COPY Caddyfile /etc/caddy/Caddyfile
COPY index.html style.css /srv/
COPY support /srv/support
COPY privacy /srv/privacy
EXPOSE 8080
