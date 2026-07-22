import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { api } from '../data/api';
import { keystore } from '../data/keystore';
import { fromBase64Url, CIRCLE_KEY_BYTES } from '../crypto/aulCrypto';
import { useMe } from '../session';
import { Login } from './Login';

/// Handles an invite link `/i/:inviteId#<base64url(K_c)>`. The key in the
/// fragment is stored locally and NEVER sent to the server; only the invite id
/// is used to accept membership.
export function Join() {
  const { t } = useTranslation();
  const { inviteId } = useParams();
  const me = useMe();
  const nav = useNavigate();
  const qc = useQueryClient();
  // Store the translation KEY (not the resolved text) so the status re-localizes
  // if the language changes, and the join effect never depends on `t`.
  const [statusKey, setStatusKey] = useState<string>('join.joining');

  useEffect(() => {
    if (me.isLoading || me.isError || !inviteId) return;
    let cancel = false;
    (async () => {
      try {
        const fragment = window.location.hash.replace(/^#/, '');
        if (!fragment) {
          setStatusKey('join.missingKey');
          return;
        }
        const key = fromBase64Url(fragment);
        if (key.length !== CIRCLE_KEY_BYTES) {
          setStatusKey('join.malformed');
          return;
        }
        const { circle_id } = await api.acceptInvite(inviteId);
        await keystore.saveCircleKey(circle_id, key);
        await qc.invalidateQueries({ queryKey: ['circles'] });
        if (!cancel) nav('/', { replace: true });
      } catch {
        if (!cancel) setStatusKey('join.failed');
      }
    })();
    return () => {
      cancel = true;
    };
  }, [me.isLoading, me.isError, inviteId, nav, qc]);

  if (me.isLoading) {
    return <div className="grid min-h-screen place-items-center text-ink-soft">…</div>;
  }
  // Not signed in: show login. The URL (with the #key) is preserved, so once
  // signed in this effect runs and completes the join.
  if (me.isError) return <Login />;

  return (
    <div className="grid min-h-screen place-items-center px-6 text-center text-ink-soft">
      {t(statusKey)}
    </div>
  );
}
