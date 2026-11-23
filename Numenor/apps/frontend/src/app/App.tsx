import { Navigate, Route, Routes } from 'react-router-dom';
import EditorPage from './EditorPage';
import LandingPage from './LandingPage';
import ProjectPage from './ProjectPage';
import CollabJoinPage from './CollabJoinPage';
import HistoryPage from './HistoryPage';
import PdfWindowPage from './PdfWindowPage';

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<LandingPage />} />
      <Route path="/projects" element={<ProjectPage />} />
      <Route path="/editor/:projectId" element={<EditorPage />} />
      <Route path="/collab" element={<CollabJoinPage />} />
      <Route path="/history/:projectId" element={<HistoryPage />} />
      <Route path="/pdf-window/:projectId" element={<PdfWindowPage />} />
      <Route path="*" element={<Navigate to="/projects" replace />} />
    </Routes>
  );
}
