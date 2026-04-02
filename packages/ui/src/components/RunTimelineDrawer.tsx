type PhaseStatus = 'pending' | 'in_progress' | 'done' | 'blocked' | undefined;

interface DrawerPhase {
  id: string;
  label: string;
  status?: PhaseStatus;
}

interface DrawerAction {
  key: string;
  label: string;
  ariaLabel: string;
  onClick: () => void;
  disabled?: boolean;
  tone?: 'neutral' | 'blue' | 'green' | 'yellow' | 'red';
}

interface DrawerRow {
  id: string;
  label: string;
  outcome: string;
  createdAt: string;
  replacementLabel?: string;
  doneText?: string;
  isSelected: boolean;
  actions: DrawerAction[];
}

interface RunTimelineDrawerProps {
  title: string;
  closeAriaLabel: string;
  onClose: () => void;
  description: string;
  workflowName: string;
  workflowSourceLabel: string;
  separationModeLabel: string;
  currentPhaseLabel: string;
  phaseOwnerLabel: string;
  agentName: string;
  reviewerName: string;
  selectedEventLabel: string;
  runStatusLabel: string;
  phases: DrawerPhase[];
  checklist: string[];
  phaseActions: DrawerAction[];
  rows: DrawerRow[];
}

function getActionStyle(tone: DrawerAction['tone']) {
  switch (tone) {
    case 'blue':
      return { background: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
    case 'green':
      return { background: 'rgba(0,206,201,0.12)', color: 'var(--green)' };
    case 'yellow':
      return { background: 'rgba(253,203,110,0.12)', color: 'var(--yellow)' };
    case 'red':
      return { background: 'rgba(255,107,107,0.08)', color: 'var(--red)' };
    default:
      return { background: 'var(--surface)', color: 'var(--text)' };
  }
}

function getPhaseStyle(status: PhaseStatus) {
  if (status === 'done') return { background: 'rgba(0,206,201,0.1)', color: 'var(--green)' };
  if (status === 'in_progress') return { background: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
  if (status === 'blocked') return { background: 'rgba(255,107,107,0.12)', color: 'var(--red)' };
  return { background: 'var(--surface3)', color: 'var(--text2)' };
}

export default function RunTimelineDrawer({
  title,
  closeAriaLabel,
  onClose,
  description,
  workflowName,
  workflowSourceLabel,
  separationModeLabel,
  currentPhaseLabel,
  phaseOwnerLabel,
  agentName,
  reviewerName,
  selectedEventLabel,
  runStatusLabel,
  phases,
  checklist,
  phaseActions,
  rows,
}: RunTimelineDrawerProps) {
  return (
    <div
      style={{
        position: 'fixed',
        top: 16,
        right: 16,
        bottom: 16,
        width: 420,
        padding: 16,
        borderRadius: 14,
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        boxShadow: '0 24px 80px rgba(0,0,0,0.28)',
        zIndex: 40,
        overflow: 'auto',
        display: 'flex',
        flexDirection: 'column',
        gap: 12,
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, alignItems: 'center' }}>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700 }}>Run Timeline Drawer</div>
          <div style={{ fontSize: 11, color: 'var(--text2)' }}>{title}</div>
        </div>
        <button
          onClick={onClose}
          aria-label={closeAriaLabel}
          style={{
            padding: '6px 10px',
            borderRadius: 8,
            border: '1px solid var(--border)',
            background: 'var(--surface2)',
            color: 'var(--text)',
            fontSize: 11,
            fontWeight: 700,
            cursor: 'pointer',
          }}
        >
          Close
        </button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 8 }}>
        <div style={{ gridColumn: '1 / -1', padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>description</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{description}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>workflow</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{workflowName}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>current phase</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{currentPhaseLabel}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>agent</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{agentName}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>reviewer</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{reviewerName}</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 8 }}>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>source</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{workflowSourceLabel}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>separation mode</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{separationModeLabel}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>selected event</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{selectedEventLabel}</div>
        </div>
        <div style={{ padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>run status</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{runStatusLabel}</div>
        </div>
        <div style={{ gridColumn: '1 / -1', padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>phase owner</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{phaseOwnerLabel}</div>
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
        <div style={{ fontSize: 10, color: 'var(--text2)' }}>phase track</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {phases.map((phase) => {
            const style = getPhaseStyle(phase.status);
            return (
              <span
                key={`drawer-phase-${phase.id}`}
                style={{
                  padding: '2px 8px',
                  borderRadius: 999,
                  background: style.background,
                  color: style.color,
                  fontSize: 10,
                  fontWeight: 700,
                }}
              >
                {phase.label}
              </span>
            );
          })}
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
        <div style={{ fontSize: 10, color: 'var(--text2)' }}>workflow checklist</div>
        {checklist.length ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {checklist.map((item) => (
              <div key={`drawer-checklist-${item}`} style={{ fontSize: 11, color: 'var(--text)' }}>
                - {item}
              </div>
            ))}
          </div>
        ) : (
          <div style={{ fontSize: 11, color: 'var(--text2)' }}>No checklist items</div>
        )}
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
        <div style={{ fontSize: 10, color: 'var(--text2)' }}>phase actions</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {phaseActions.map((action) => {
            const tone = getActionStyle(action.tone);
            return (
              <button
                key={action.key}
                onClick={action.onClick}
                disabled={action.disabled}
                aria-label={action.ariaLabel}
                style={{
                  padding: '4px 8px',
                  borderRadius: 8,
                  border: '1px solid var(--border)',
                  background: tone.background,
                  color: tone.color,
                  fontSize: 10,
                  fontWeight: 700,
                  cursor: action.disabled ? 'not-allowed' : 'pointer',
                  opacity: action.disabled ? 0.6 : 1,
                }}
              >
                {action.label}
              </button>
            );
          })}
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {rows.map((row) => (
          <div
            key={row.id}
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              gap: 8,
              padding: '8px 10px',
              borderRadius: 10,
              border: `1px solid ${row.isSelected ? 'var(--accent)' : 'var(--border)'}`,
              background: 'var(--surface2)',
            }}
          >
            <div style={{ display: 'flex', flex: 1, flexDirection: 'column', gap: 4 }}>
              <span style={{ fontSize: 11, fontWeight: 700 }}>{row.label}</span>
              <span style={{ fontSize: 10, color: 'var(--text2)' }}>{row.outcome}</span>
              <span style={{ fontSize: 10, color: 'var(--text2)' }}>{row.createdAt}</span>
              {row.replacementLabel ? (
                <span style={{ fontSize: 10, color: 'var(--blue)' }}>{row.replacementLabel}</span>
              ) : null}
              {row.doneText ? (
                <span style={{ fontSize: 10, color: 'var(--text2)' }}>{row.doneText}</span>
              ) : null}
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {row.actions.map((action) => {
                const tone = getActionStyle(action.tone);
                return (
                  <button
                    key={action.key}
                    onClick={action.onClick}
                    disabled={action.disabled}
                    aria-label={action.ariaLabel}
                    style={{
                      padding: '4px 8px',
                      borderRadius: 8,
                      border: '1px solid var(--border)',
                      background: tone.background,
                      color: tone.color,
                      fontSize: 10,
                      fontWeight: 700,
                      cursor: action.disabled ? 'not-allowed' : 'pointer',
                      opacity: action.disabled ? 0.6 : 1,
                    }}
                  >
                    {action.label}
                  </button>
                );
              })}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
