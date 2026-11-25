import { lazy, Suspense } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import EditorPage from './EditorPage';
import LandingPage from './LandingPage';
import ProjectPage from './ProjectPage';
import CollabJoinPage from './CollabJoinPage';
import HistoryPage from './HistoryPage';
import PdfWindowPage from './PdfWindowPage';
import OutlineWindow from './OutlineWindow';
import ChatWindow from './ChatWindow';
import WorkspaceChat from './WorkspaceChat';
import { UpdateProvider } from './UpdateNotice';

const Library2 = lazy(() => import('../research/Library2.jsx'));
const Reader2 = lazy(() => import('../research/Reader2.jsx'));

export default function App() {
  return (
    <UpdateProvider>
    <Suspense fallback={<p role="status">Loading…</p>}>
    <Routes>
      <Route path="/" element={<LandingPage />} />
      <Route path="/projects" element={<ProjectPage />} />
      <Route path="/editor/:projectId" element={<EditorPage />} />
      <Route path="/collab" element={<CollabJoinPage />} />
      <Route path="/history/:projectId" element={<HistoryPage />} />
      <Route path="/workspace-ai" element={<WorkspaceChat />} />
      <Route path="/chat-window/:projectId" element={<ChatWindow />} />
      <Route path="/outline-window/:projectId" element={<OutlineWindow />} />
      <Route path="/pdf-window/:projectId" element={<PdfWindowPage />} />
      <Route path="/library2" element={<Library2 />} />
      <Route path="/reader2/:paperId" element={<Reader2 />} />
      <Route path="/reader2" element={<Navigate to="/library2" replace />} />
      <Route path="*" element={<Navigate to="/projects" replace />} />
    </Routes>
    </Suspense>
    </UpdateProvider>
  );
}
