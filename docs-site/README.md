# ClipSlop docs site

Docusaurus app for [https://mekedron.github.io/clipslop/](https://mekedron.github.io/clipslop/).

Markdown content lives at the repo root in `../docs/`. This folder only holds the build configuration, the landing page, and the theme.

## Run locally

```bash
npm install
npm start
```

Opens [http://localhost:3000/clipslop/](http://localhost:3000/clipslop/) with hot reload.

## Production build

```bash
npm run build
npm run serve
```

`npm run build` is what the GitHub Actions deploy workflow runs. It must pass before pushing — `onBrokenLinks` is set to `throw`.

## Deployment

Pushes to `main` trigger `.github/workflows/deploy-docs.yml`, which builds this site and publishes to GitHub Pages via `actions/deploy-pages@v4`. PRs run `.github/workflows/test-docs-build.yml`, which only builds (no deploy).

GitHub Pages must be configured with **Source = GitHub Actions** in the repo settings.
