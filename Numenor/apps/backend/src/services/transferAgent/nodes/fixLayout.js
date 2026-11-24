import { promises as fs } from 'fs';
import { activeChatModel } from '../../llmService.js';
import { safeJoin } from '../../../utils/pathUtils.js';
import { writeFileWithSnapshot, stripCodeFences } from '../utils.js';

/**
 * fixLayout node — LLM reads current main.tex + VLM layout issues,
 * adjusts LaTeX to fix layout problems.
 */
export async function fixLayout(state) {
  const absMain = safeJoin(state.targetProjectRoot, state.targetMainFile);
  const currentTex = await fs.readFile(absMain, 'utf8');

  const issues = state.layoutCheckResult?.issues || [];
  const issuesText = JSON.stringify(issues, null, 2);

  const llm = activeChatModel();

  const prompt = `You are a LaTeX layout fixer.

The following LaTeX file has layout issues identified by visual inspection.
Fix the issues and return the corrected COMPLETE file.

LAYOUT ISSUES:
${issuesText}

CURRENT FILE (${state.targetMainFile}):
${currentTex}

Common layout fixes:
- Overflow: adjust figure width, use \\resizebox, or \\adjustbox
- Overlap: use [H] or [htbp] float placement, add \\clearpage
- Spacing: adjust \\vspace, \\baselineskip, or use \\newpage
- Tables too wide: use tabularx, resizebox, or reduce columns

Output ONLY the complete corrected LaTeX file. No explanations, no markdown fences.`;

  const response = await llm.invoke([{ role: 'user', content: prompt }]);
  const fixed = stripCodeFences(response.content);

  await writeFileWithSnapshot(
    state.targetProjectRoot,
    state.targetMainFile,
    fixed,
    state.jobId
  );

  return {
    progressLog: `[fixLayout] Applied LLM fix for ${issues.length} layout issues (attempt ${state.layoutAttempt}).`,
  };
}
