// Numenor started as OpenPrism: carry this browser's saved settings over to the new key names once
// (interface language, AI/collab settings, Maziar's remembered positions per project).
try {
  for (let i = 0; i < localStorage.length; i += 1) {
    const key = localStorage.key(i);
    if (!key) continue;
    const renamed = key.startsWith('openprism-')
      ? `numenor-${key.slice('openprism-'.length)}`
      : key.startsWith('maziar.openprism.')
        ? `maziar.numenor.${key.slice('maziar.openprism.'.length)}`
        : '';
    if (renamed && localStorage.getItem(renamed) === null) {
      localStorage.setItem(renamed, localStorage.getItem(key) ?? '');
    }
  }
} catch {
  /* storage unavailable */
}

export {};
