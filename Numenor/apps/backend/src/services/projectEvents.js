// A tiny "this project changed" signal, so services that react to saves (copies kept in other folders —
// see syncService.js) don't have to be wired into every route that writes a file.
import { EventEmitter } from 'events';
import path from 'path';

export const projectEvents = new EventEmitter();
projectEvents.setMaxListeners(50);

/** kind: 'save' (a file changed) or 'compile' (a new PDF was built). */
export function projectChanged(projectRoot, kind = 'save') {
  if (!projectRoot) return;
  projectEvents.emit('changed', { projectRoot, projectId: path.basename(projectRoot), kind });
}
