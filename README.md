# acme-portal-static

Static multi-page portal served from nginx. Test fixture for HTML containerization (CZ) rule detection.
Each cz-html-* rule (1000-1017) is triggered at least once. See the accompanying TRUTH document.

## Structure

This is a single, standard Maven project (one `pom.xml` at the repo root — no nested
or multi-module POMs) with Java source alongside the static frontend assets:

- Backend (Java) — `src/main/java/com/trianz/acmeportal/`, exposing `GET /api/health`.
  Build with `mvn package` from the repo root; run with `java -jar target/acme-portal-static.jar`.
- Frontend (HTML + CSS) — repo root (`index.html`, `app/`, `pages/`, `forms/`, `partials/`,
  `assets/`), static pages served by nginx.

## Note on cz-html-1009 (Unminified HTML)

This rule fires on nearly every line of every non-minified HTML file by design — it is a
per-line style heuristic, not a single-site trigger. Reducing it to one instance would require
minifying every page into unreadable single-line markup, which would defeat the purpose of a
readable, maintainable fixture and obscure the other rule triggers documented above. It is
intentionally left as the one exception to "one violation per rule."
