import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import zhCN from './locales/zh-CN.json';
import enUS from './locales/en-US.json';
import ptPT from './locales/pt-PT.json';

export const interfaceLanguages = [['zh-CN', '中文'], ['en-US', 'English'], ['pt-PT', 'Português']] as const;
export const interfaceLanguageLabel = (code: string) =>
  interfaceLanguages.find(([language]) => language === code)?.[1] ?? 'English';

const STORAGE_KEY = 'numenor-lang';
const defaultLang = 'zh-CN';

function getInitialLang() {
  if (typeof window === 'undefined') return defaultLang;
  const stored = window.localStorage.getItem(STORAGE_KEY);
  if (stored === 'zh-CN' || stored === 'en-US' || stored === 'pt-PT') return stored;
  // First visit (e.g. someone opening an invite link): follow the browser's language.
  const browser = (window.navigator?.language || '').toLowerCase();
  return browser.startsWith('zh') ? 'zh-CN' : browser.startsWith('pt') ? 'pt-PT' : 'en-US';
}

const initialLanguage = getInitialLang();
if (typeof document !== 'undefined') document.documentElement.lang = initialLanguage;

void i18n
  .use(initReactI18next)
  .init({
    resources: {
      'zh-CN': { translation: zhCN },
      'en-US': { translation: enUS },
      'pt-PT': { translation: ptPT }
    },
    lng: initialLanguage,
    fallbackLng: { 'pt-PT': ['en-US'], default: [defaultLang] },
    interpolation: { escapeValue: false },
    keySeparator: false
  });

i18n.on('languageChanged', (lng) => {
  if (typeof window === 'undefined') return;
  document.documentElement.lang = lng;
  if (interfaceLanguages.some(([language]) => language === lng)) {
    window.localStorage.setItem(STORAGE_KEY, lng);
  }
});

export default i18n;
export const LANGUAGE_STORAGE_KEY = STORAGE_KEY;
