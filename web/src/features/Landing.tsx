import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { Trans, useTranslation } from 'react-i18next';
import {
  ArrowRight,
  Ban,
  Download,
  Link2,
  MapPinned,
  Server,
  ShieldAlert,
  ShieldCheck,
  Users,
} from 'lucide-react';

import type { UserDTO } from '../data/types';
import { LanguageSwitcher } from '../i18n/LanguageSwitcher';
import { ThemeSwitcher } from './ThemeSwitcher';

const GITHUB_URL = 'https://github.com/aul-app/aul';
const THREAT_MODEL_URL = 'https://github.com/aul-app/aul/blob/main/docs/THREAT_MODEL.md';

/// The GitHub wordmark isn't in this lucide build, so we inline the mark.
export function GithubMark({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .5A11.5 11.5 0 0 0 .5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.7 0-1.26.45-2.28 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.8 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.12 3.05.74.81 1.18 1.83 1.18 3.09 0 4.43-2.69 5.4-5.25 5.69.41.36.78 1.05.78 2.12v3.14c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12 11.5 11.5 0 0 0 12 .5Z" />
    </svg>
  );
}

const btnPrimary =
  'inline-flex items-center justify-center gap-2 rounded-full bg-primary px-6 py-3 font-semibold text-[var(--landing-on-primary)] shadow-sm transition-colors hover:bg-primary-hover';
const btnSecondary =
  'inline-flex items-center justify-center gap-2 rounded-full border border-line bg-surface px-6 py-3 font-semibold text-ink transition-colors hover:border-primary';

const VALUE_PROPS = [
  { icon: ShieldCheck, key: 'e2e' },
  { icon: Ban, key: 'noSelling' },
  { icon: Server, key: 'selfHost' },
  { icon: ShieldAlert, key: 'antiStalk' },
] as const;

const STEPS = [
  { icon: Users, key: 'create' },
  { icon: Link2, key: 'invite' },
  { icon: MapPinned, key: 'seeMap' },
] as const;

const FAQ = ['1', '2', '3', '4', '5'] as const;

export function Landing() {
  const { t } = useTranslation();
  // Read the cached auth state WITHOUT subscribing: calling useMe() here would
  // add a second observer to the ['me'] query. When signed out that query is in
  // an error state, and a fresh observer's refetch-on-mount flips Home back to
  // its loading branch — which unmounts this component, re-mounts it, and loops
  // (an infinite /v1/account/me storm). getQueryData is non-reactive and safe.
  const loggedIn = !!useQueryClient().getQueryData<UserDTO>(['me']);

  return (
    <div className="landing min-h-screen bg-bg text-ink">
      {/* Header */}
      <header className="sticky top-0 z-30 border-b border-line bg-bg/80 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center gap-4 px-6 py-3">
          <Link to="/" className="text-2xl font-extrabold text-primary" style={{ fontFamily: 'var(--font-heading)' }}>
            Aul
          </Link>
          <nav className="ml-auto flex items-center gap-2 sm:gap-4">
            {/* Theme + language, on their own wrapper so the `hidden sm:flex`
                lives here and never fights the switchers' own display class.
                Below sm there is no room next to Sign in + Download — the footer
                carries both controls for those viewports. */}
            <div className="hidden items-center gap-2 sm:flex">
              <ThemeSwitcher />
              <LanguageSwitcher />
            </div>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="hidden items-center gap-1.5 text-sm font-medium text-ink-soft transition-colors hover:text-ink sm:inline-flex"
            >
              <GithubMark size={16} /> GitHub
            </a>
            <Link to="/login" className="text-sm font-medium text-ink-soft transition-colors hover:text-ink">
              {t('landing.header.signIn')}
            </Link>
            <Link
              to="/download"
              className="inline-flex items-center gap-1.5 rounded-full bg-primary px-4 py-2 text-sm font-semibold text-[var(--landing-on-primary)] transition-colors hover:bg-primary-hover"
            >
              <Download size={16} /> {t('landing.header.download')}
            </Link>
          </nav>
        </div>
      </header>

      {/* Hero */}
      <section className="mx-auto max-w-3xl px-6 py-16 md:py-24">
        <div>
          <span className="inline-flex items-center gap-2 rounded-full border border-line bg-surface px-3 py-1 text-xs font-medium text-ink-soft">
            <ShieldCheck size={14} className="text-primary" /> {t('landing.hero.badge')}
          </span>
          <h1
            className="mt-5 text-4xl font-extrabold leading-tight tracking-tight sm:text-5xl"
            style={{ fontFamily: 'var(--font-heading)' }}
          >
            {t('landing.hero.titleLead')}{' '}
            <span className="text-primary">{t('landing.hero.titleHighlight')}</span>
          </h1>
          <p className="mt-4 max-w-xl text-lg text-ink-soft">{t('landing.hero.subtitle')}</p>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <Link to="/download" className={btnPrimary}>
              <Download size={18} /> {t('landing.hero.downloadAndroid')}
            </Link>
            <Link to="/login" className={btnSecondary}>
              {t('landing.hero.openWebApp')} <ArrowRight size={18} />
            </Link>
          </div>
          {loggedIn && (
            <Link
              to="/"
              className="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
            >
              {t('landing.hero.openDashboard')} <ArrowRight size={14} />
            </Link>
          )}
          <p className="mt-6 flex items-center gap-2 text-sm text-ink-soft">
            <Ban size={15} /> {t('landing.hero.noAds')}
          </p>
        </div>
      </section>

      {/* Value props */}
      <section className="mx-auto max-w-6xl px-6 py-12">
        <div className="grid gap-5 sm:grid-cols-2">
          {VALUE_PROPS.map(({ icon: Icon, key }) => (
            <div key={key} className="rounded-[var(--radius-card)] border border-line bg-surface p-6 shadow-sm">
              <div className="grid h-11 w-11 place-items-center rounded-full bg-primary/10 text-primary">
                <Icon size={22} />
              </div>
              <h3 className="mt-4 text-lg font-bold">{t(`landing.valueProps.${key}.title`)}</h3>
              <p className="mt-2 text-ink-soft">{t(`landing.valueProps.${key}.body`)}</p>
            </div>
          ))}
        </div>
      </section>

      {/* How it works */}
      <section className="mx-auto max-w-6xl px-6 py-12">
        <h2 className="text-center text-3xl font-extrabold" style={{ fontFamily: 'var(--font-heading)' }}>
          {t('landing.howItWorks')}
        </h2>
        <div className="mt-10 grid gap-6 md:grid-cols-3">
          {STEPS.map(({ icon: Icon, key }, i) => (
            <div key={key} className="relative rounded-[var(--radius-card)] border border-line bg-surface p-6">
              <div className="flex items-center gap-3">
                <span className="grid h-9 w-9 place-items-center rounded-full bg-primary font-bold text-[var(--landing-on-primary)]">
                  {i + 1}
                </span>
                <Icon size={22} className="text-primary" />
              </div>
              <h3 className="mt-4 text-lg font-bold">{t(`landing.steps.${key}.title`)}</h3>
              <p className="mt-2 text-ink-soft">{t(`landing.steps.${key}.body`)}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Open source / self-host strip */}
      <section className="mx-auto max-w-6xl px-6 py-12">
        <div className="rounded-[var(--radius-card)] border border-line bg-primary/5 p-8 md:flex md:items-center md:gap-8">
          <div className="md:flex-1">
            <h2 className="text-2xl font-extrabold" style={{ fontFamily: 'var(--font-heading)' }}>
              {t('landing.oss.title')}
            </h2>
            <p className="mt-3 max-w-2xl text-ink-soft">
              <Trans i18nKey="landing.oss.body" components={{ b: <strong className="text-ink" /> }} />
            </p>
            <pre className="mt-5 overflow-x-auto rounded-[var(--radius-control)] border border-line bg-bg px-4 py-3 font-mono text-sm text-ink">
              docker compose -f deploy/docker-compose.yml up -d
            </pre>
          </div>
          <div className="mt-6 md:mt-0">
            <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={btnSecondary}>
              <GithubMark /> {t('landing.oss.viewGithub')}
            </a>
          </div>
        </div>
      </section>

      {/* FAQ */}
      <section className="mx-auto max-w-3xl px-6 py-12">
        <h2 className="text-center text-3xl font-extrabold" style={{ fontFamily: 'var(--font-heading)' }}>
          {t('landing.faq.title')}
        </h2>
        <div className="mt-8 divide-y divide-line rounded-[var(--radius-card)] border border-line bg-surface">
          {FAQ.map((n) => (
            <details key={n} className="group px-6 py-4">
              <summary className="flex cursor-pointer list-none items-center justify-between font-semibold">
                {t(`landing.faq.q${n}`)}
                <ArrowRight size={18} className="text-ink-soft transition-transform group-open:rotate-90" />
              </summary>
              <p className="mt-3 text-ink-soft">{t(`landing.faq.a${n}`)}</p>
            </details>
          ))}
        </div>
      </section>

      {/* Final CTA */}
      <section className="mx-auto max-w-6xl px-6 py-16 text-center">
        <h2 className="text-3xl font-extrabold" style={{ fontFamily: 'var(--font-heading)' }}>
          {t('landing.finalCta')}
        </h2>
        <div className="mt-8 flex flex-wrap justify-center gap-3">
          <Link to="/download" className={btnPrimary}>
            <Download size={18} /> {t('landing.hero.downloadAndroid')}
          </Link>
          <Link to="/login" className={btnSecondary}>
            {t('landing.hero.openWebApp')} <ArrowRight size={18} />
          </Link>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-line">
        <div className="mx-auto flex max-w-6xl flex-col items-center gap-4 px-6 py-8 text-sm text-ink-soft sm:flex-row">
          <span className="font-extrabold text-primary" style={{ fontFamily: 'var(--font-heading)' }}>
            Aul
          </span>
          <nav className="flex flex-wrap items-center gap-4 sm:ml-auto">
            <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1.5 hover:text-ink">
              <GithubMark size={16} /> GitHub
            </a>
            <Link to="/download" className="hover:text-ink">
              {t('landing.footer.download')}
            </Link>
            <a href={THREAT_MODEL_URL} target="_blank" rel="noreferrer" className="hover:text-ink">
              {t('landing.footer.threatModel')}
            </a>
            <ThemeSwitcher />
            <LanguageSwitcher />
          </nav>
        </div>
      </footer>
    </div>
  );
}
