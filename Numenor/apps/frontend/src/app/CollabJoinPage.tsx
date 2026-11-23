import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { resolveCollabToken, setCollabServer, setCollabToken } from '../api/client';

export default function CollabJoinPage() {
  const navigate = useNavigate();
  const { t } = useTranslation();
  const [status, setStatus] = useState(t('正在加入协作...'));

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const token = params.get('token') || '';
    if (!token) {
      setStatus(t('邀请链接缺少 token。'));
      return;
    }
    setCollabServer(window.location.origin);
    setStatus(t('正在验证邀请...'));
    resolveCollabToken(token)
      .then((res) => {
        if (!res.ok || !res.projectId) {
          setStatus(t('邀请无效或已过期。'));
          return;
        }
        setCollabToken(token);
        setStatus(t('已加入协作，正在打开项目...'));
        navigate(`/editor/${res.projectId}`, { replace: true });
      })
      .catch((err) => {
        const msg = String((err as Error)?.message || err);
        if (/removed/i.test(msg)) setStatus(t('Your access to this project was removed by its owner.'));
        else if (/invalid token/i.test(msg)) setStatus(t('This invite link isn’t valid (it may have been replaced). Ask the owner for a new one.'));
        else setStatus(t('加入失败: {{error}}', { error: msg }));
      });
  }, [navigate, t]);

  return (
    <div className="collab-join">
      <div className="panel collab-join-card">
        <div className="panel-header">{t('协作加入')}</div>
        <div className="collab-join-body">
          <div className="muted">{status}</div>
        </div>
      </div>
    </div>
  );
}
