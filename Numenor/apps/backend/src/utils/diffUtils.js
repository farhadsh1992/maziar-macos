export function extractPathFromPatch(patch) {
  const lines = patch.split('\n');
  for (const line of lines) {
    if (line.startsWith('+++ ')) {
      let filePath = line.slice(4).trim();
      if (filePath.startsWith('b/')) filePath = filePath.slice(2);
      return filePath;
    }
  }
  for (const line of lines) {
    if (line.startsWith('--- ')) {
      let filePath = line.slice(4).trim();
      if (filePath.startsWith('a/')) filePath = filePath.slice(2);
      return filePath;
    }
  }
  return '';
}
