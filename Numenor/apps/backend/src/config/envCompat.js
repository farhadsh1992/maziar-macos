// Numenor started as OpenPrism. Settings given the old way (OPENPRISM_* environment variables) keep
// working: each one fills in its NUMENOR_* counterpart when that isn't set. Imported first by index.js.
for (const [key, value] of Object.entries(process.env)) {
  if (key.startsWith('OPENPRISM_')) {
    const renamed = `NUMENOR_${key.slice('OPENPRISM_'.length)}`;
    if (process.env[renamed] === undefined) process.env[renamed] = value;
  }
}
