import { Navigate, Route, Routes } from 'react-router-dom';
import EditorPage from './EditorPage';
import LandingPage from './LandingPage';
import ProjectPage from './ProjectPage';
import CollabJoinPage from './CollabJoinPage';
import HistoryPage from './HistoryPage';
import PdfWindowPage from './PdfWindowPage';
import OutlineWindow from './OutlineWindow';
import { UpdateProvider } from './UpdateNotice';

export default function App() {
  return (
    <UpdateProvider>
    <Routes>
      <Route path="/" element={<LandingPage />} />
      <Route path="/projects" element={<ProjectPage />} />
      <Route path="/editor/:projectId" element={<EditorPage />} />
      <Route path="/collab" element={<CollabJoinPage />} />
      <Route path="/history/:projectId" element={<HistoryPage />} />
      <Route path="/outline-window/:projectId" element={<OutlineWindow />} />
      <Route path="/pdf-window/:projectId" element={<PdfWindowPage />} />
      <Route path="*" element={<Navigate to="/projects" replace />} />
    </Routes>
    </UpdateProvider>
  );
}
