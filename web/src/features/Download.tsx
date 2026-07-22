import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Trans, useTranslation } from 'react-i18next';
import {
  ArrowLeft,
  Apple,
  Check,
  Copy,
  Download as DownloadIcon,
  RefreshCw,
  ShieldCheck,
  Smartphone,
} from 'lucide-react';

import { api, ApiError } from '../data/api';
import { GithubMark } from './Landing';

const GITHUB_URL = 'https://github.com/aul-app/aul';

const card = 'rounded-[var(--radius-card)] border border-line bg-surface p-6 shadow-sm';
const btnPrimary =
  'inline-flex items-center justify-center gap-2 rounded-full bg-primary px-6 py-3 font-semibold text-[var(--landing-on-primary)] shadow-sm transition-colors hover:bg-primary-hover';
const btnSecondary =
  'inline-flex items-center justify-center gap-2 rounded-full border border-line bg-surface px-6 py-3 font-semibold text-ink transition-colors hover:border-primary';

/// A copyable monospace block for the release SHA-256, so a self-hoster can
/// `sha256sum` the APK and compare before installing.
function Sha256Block({ sha256, versionName }: { sha256: string; versionName: string }) {
  const { t } = useTranslation();
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard?.writeText(sha256);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard unavailable (insecure context) — the digest is still visible */
    }
  }

  return (
    <div className="mt-5">
      <div className="flex items-center justify-between gap-3">
        <span className="text-sm font-semibold text-ink-soft">SHA-256</span>
        <button
          type="button"
          onClick={copy}
          className="inline-flex items-center gap-1.5 rounded-full border border-line px-3 py-1 text-xs font-medium text-ink-soft transition-colors hover:border-primary hover:text-ink"
        >
          {copied ? <Check size={13} /> : <Copy size={13} />}
          {copied ? t('common.copied') : t('common.copy')}
        </button>
      </div>
      <code className="mt-2 block overflow-x-auto rounded-[var(--radius-control)] border border-line bg-bg px-4 py-3 font-mono text-sm break-all text-ink">
        {sha256}
      </code>
      <p className="mt-2 font-mono text-xs text-ink-soft">
        {t('download.sha.verify', { version: versionName })}
      </p>
    </div>
  );
}

/// The Android APK card once a version is published.
function AndroidRelease({
  versionName,
  versionCode,
  apkUrl,
  sha256,
  changelog,
}: {
  versionName: string;
  versionCode: number;
  apkUrl: string;
  sha256: string;
  changelog: string;
}) {
  const { t } = useTranslation();
  return (
    <div className={card}>
      <div className="flex items-center gap-3">
        <div className="grid h-11 w-11 place-items-center rounded-full bg-primary/10 text-primary">
          <Smartphone size={22} />
        </div>
        <div>
          <h2 className="text-lg font-bold">{t('download.android.title')}</h2>
          <p className="text-sm text-ink-soft">
            {t('download.android.version', { name: versionName })}{' '}
            <span className="text-ink-soft/70">{t('download.android.build', { code: versionCode })}</span>
          </p>
        </div>
      </div>

      {changelog && (
        <p className="mt-4 whitespace-pre-line text-ink-soft">{changelog}</p>
      )}

      {apkUrl ? (
        <a href={apkUrl} className={`${btnPrimary} mt-5 w-full sm:w-auto`}>
          <DownloadIcon size={18} /> {t('download.android.downloadApk')}
        </a>
      ) : (
        <p className="mt-5 text-sm text-ink-soft">
          <Trans
            i18nKey="download.android.noApk"
            components={{
              a: <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="font-medium text-primary hover:underline" />,
            }}
          />
        </p>
      )}

      {sha256 && <Sha256Block sha256={sha256} versionName={versionName} />}

      <div className="mt-6 rounded-[var(--radius-control)] border border-line bg-bg p-4 text-sm text-ink-soft">
        <p className="font-semibold text-ink">{t('download.android.installTitle')}</p>
        <p className="mt-1">
          <Trans
            i18nKey="download.android.installBody"
            components={{ b: <span className="font-medium text-ink" /> }}
          />
        </p>
      </div>
    </div>
  );
}

export function Download() {
  const { t } = useTranslation();
  const q = useQuery({
    queryKey: ['version', 'android'],
    queryFn: () => api.versionLatest('android'),
    retry: false,
    staleTime: 60_000,
  });

  const notPublished = q.isError && q.error instanceof ApiError && q.error.status === 404;

  return (
    <div className="landing min-h-screen bg-bg text-ink">
      {/* Header */}
      <header className="border-b border-line bg-bg/80 backdrop-blur">
        <div className="mx-auto flex max-w-3xl items-center gap-4 px-6 py-3">
          <Link to="/" className="inline-flex items-center gap-1.5 text-sm font-medium text-ink-soft hover:text-ink">
            <ArrowLeft size={16} /> {t('download.back')}
          </Link>
          <Link
            to="/"
            className="ml-auto text-xl font-extrabold text-primary"
            style={{ fontFamily: 'var(--font-heading)' }}
          >
            Aul
          </Link>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-6 py-12">
        <h1 className="text-3xl font-extrabold sm:text-4xl" style={{ fontFamily: 'var(--font-heading)' }}>
          {t('download.title')}
        </h1>
        <p className="mt-3 text-ink-soft">{t('download.subtitle')}</p>

        <div className="mt-8 space-y-6">
          {/* Android */}
          {q.isLoading && (
            <div className={`${card} animate-pulse`}>
              <div className="h-11 w-11 rounded-full bg-line" />
              <div className="mt-4 h-4 w-40 rounded bg-line" />
              <div className="mt-3 h-4 w-full rounded bg-line" />
              <div className="mt-5 h-11 w-48 rounded-full bg-line" />
            </div>
          )}

          {notPublished && (
            <div className={card}>
              <div className="flex items-center gap-3">
                <div className="grid h-11 w-11 place-items-center rounded-full bg-primary/10 text-primary">
                  <Smartphone size={22} />
                </div>
                <h2 className="text-lg font-bold">{t('download.android.title')}</h2>
              </div>
              <p className="mt-4 text-ink-soft">
                <Trans i18nKey="download.notPublished.body" components={{ b: <span className="font-semibold text-ink" /> }} />
              </p>
              <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={`${btnSecondary} mt-5`}>
                <GithubMark /> {t('download.notPublished.build')}
              </a>
            </div>
          )}

          {q.isError && !notPublished && (
            <div className={card}>
              <h2 className="text-lg font-bold">{t('download.error.title')}</h2>
              <p className="mt-2 text-ink-soft">{t('download.error.body')}</p>
              <button type="button" onClick={() => q.refetch()} className={`${btnSecondary} mt-5`}>
                <RefreshCw size={18} /> {t('download.error.retry')}
              </button>
            </div>
          )}

          {q.isSuccess && q.data && (
            <AndroidRelease
              versionName={q.data.version_name}
              versionCode={q.data.version_code}
              apkUrl={q.data.apk_url}
              sha256={q.data.sha256}
              changelog={q.data.changelog}
            />
          )}

          {/* iOS */}
          <div className={card}>
            <div className="flex items-center gap-3">
              <div className="grid h-11 w-11 place-items-center rounded-full bg-primary/10 text-primary">
                <Apple size={22} />
              </div>
              <div>
                <h2 className="text-lg font-bold">{t('download.ios.title')}</h2>
                <p className="text-sm text-ink-soft">{t('download.ios.subtitle')}</p>
              </div>
            </div>
            <p className="mt-4 text-ink-soft">{t('download.ios.body')}</p>
            <Link to="/login" className={`${btnSecondary} mt-5`}>
              {t('download.ios.openWebApp')}
            </Link>
          </div>
        </div>

        <p className="mt-10 flex items-center gap-2 text-sm text-ink-soft">
          <ShieldCheck size={16} className="text-primary" />
          {t('download.footer')}
        </p>
      </main>
    </div>
  );
}
