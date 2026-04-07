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

interface DrawerAlert {
  label: string;
  tone: 'blue' | 'green' | 'yellow' | 'red';
}

interface DrawerChecklistItem {
  label: string;
  kind: 'required' | 'advisory' | 'evidence';
  done: boolean;
  highlighted?: boolean;
  ariaLabel: string;
  onToggle: () => void;
  disabled?: boolean;
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
  setupOriginLabels: string[];
  separationModeLabel: string;
  alerts: DrawerAlert[];
  currentPhaseLabel: string;
  phaseObjectiveLabel: string;
  phasePolicyLines: string[];
  phaseOwnerLabel: string;
  agentName: string;
  agentCapabilityLabels: string[];
  reviewerName: string;
  reviewerCapabilityLabels: string[];
  selectedEventLabel: string;
  runStatusLabel: string;
  executionBadges: DrawerAlert[];
  executionSummaryLines: string[];
  phases: DrawerPhase[];
  checklistItems: DrawerChecklistItem[];
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

function getChecklistKindStyle(kind: DrawerChecklistItem['kind']) {
  if (kind === 'required') return { background: 'rgba(255,107,107,0.08)', color: 'var(--red)' };
  if (kind === 'evidence') return { background: 'rgba(253,203,110,0.12)', color: 'var(--yellow)' };
  return { background: 'rgba(116,185,255,0.12)', color: 'var(--blue)' };
}

export default function RunTimelineDrawer({
  title,
  closeAriaLabel,
  onClose,
  description,
  workflowName,
  workflowSourceLabel,
  setupOriginLabels,
  separationModeLabel,
  alerts,
  currentPhaseLabel,
  phaseObjectiveLabel,
  phasePolicyLines,
  phaseOwnerLabel,
  agentName,
  agentCapabilityLabels,
  reviewerName,
  reviewerCapabilityLabels,
  selectedEventLabel,
  runStatusLabel,
  executionBadges,
  executionSummaryLines,
  phases,
  checklistItems,
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
        <div style={{ gridColumn: '1 / -1', padding: '8px 10px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)' }}>phase objective</div>
          <div style={{ fontSize: 11, fontWeight: 700 }}>{phaseObjectiveLabel}</div>
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

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 8 }}>
        <div style={{ padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 6 }}>setup origin</div>
          {setupOriginLabels.length ? (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {setupOriginLabels.map((label) => (
                <span
                  key={`setup-origin-${label}`}
                  style={{
                    padding: '2px 8px',
                    borderRadius: 999,
                    background: 'rgba(0,206,201,0.12)',
                    color: 'var(--green)',
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {label}
                </span>
              ))}
            </div>
          ) : (
            <div style={{ fontSize: 11, color: 'var(--text2)' }}>No setup origin data</div>
          )}
        </div>
        <div style={{ padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 6 }}>phase policy</div>
          {phasePolicyLines.length ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {phasePolicyLines.map((line) => (
                <div key={`phase-policy-${line}`} style={{ fontSize: 11, color: 'var(--text)' }}>
                  - {line}
                </div>
              ))}
            </div>
          ) : (
            <div style={{ fontSize: 11, color: 'var(--text2)' }}>No phase policy notes</div>
          )}
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
        <div style={{ fontSize: 10, color: 'var(--text2)' }}>orchestration alerts</div>
        {alerts.length ? (
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {alerts.map((alert) => {
              const tone = getActionStyle(alert.tone);
              return (
                <span
                  key={`drawer-alert-${alert.label}`}
                  style={{
                    padding: '2px 8px',
                    borderRadius: 999,
                    background: tone.background,
                    color: tone.color,
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {alert.label}
                </span>
              );
            })}
          </div>
        ) : (
          <div style={{ fontSize: 11, color: 'var(--text2)' }}>No orchestration alerts</div>
        )}
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
        <div style={{ fontSize: 10, color: 'var(--text2)' }}>execution evidence</div>
        {executionBadges.length ? (
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {executionBadges.map((badge) => {
              const tone = getActionStyle(badge.tone);
              return (
                <span
                  key={`drawer-execution-${badge.label}`}
                  style={{
                    padding: '2px 8px',
                    borderRadius: 999,
                    background: tone.background,
                    color: tone.color,
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {badge.label}
                </span>
              );
            })}
          </div>
        ) : (
          <div style={{ fontSize: 11, color: 'var(--text2)' }}>No execution badge evidence</div>
        )}
        {executionSummaryLines.length ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {executionSummaryLines.map((line) => (
              <div key={`drawer-execution-line-${line}`} style={{ fontSize: 11, color: 'var(--text)' }}>
                - {line}
              </div>
            ))}
          </div>
        ) : (
          <div style={{ fontSize: 11, color: 'var(--text2)' }}>No execution summary evidence</div>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 8 }}>
        <div style={{ padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 6 }}>agent capabilities</div>
          {agentCapabilityLabels.length ? (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {agentCapabilityLabels.map((label) => (
                <span
                  key={`agent-capability-${label}`}
                  style={{
                    padding: '2px 8px',
                    borderRadius: 999,
                    background: 'rgba(116,185,255,0.12)',
                    color: 'var(--blue)',
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {label}
                </span>
              ))}
            </div>
          ) : (
            <div style={{ fontSize: 11, color: 'var(--text2)' }}>No agent capability data</div>
          )}
        </div>
        <div style={{ padding: '10px 12px', borderRadius: 10, background: 'var(--surface2)', border: '1px solid var(--border)' }}>
          <div style={{ fontSize: 10, color: 'var(--text2)', marginBottom: 6 }}>reviewer capabilities</div>
          {reviewerCapabilityLabels.length ? (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {reviewerCapabilityLabels.map((label) => (
                <span
                  key={`reviewer-capability-${label}`}
                  style={{
                    padding: '2px 8px',
                    borderRadius: 999,
                    background: 'rgba(253,203,110,0.12)',
                    color: 'var(--yellow)',
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  {label}
                </span>
              ))}
            </div>
          ) : (
            <div style={{ fontSize: 11, color: 'var(--text2)' }}>No reviewer capability data</div>
          )}
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
        {checklistItems.length ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {checklistItems.map((item) => (
              (() => {
                const kindStyle = getChecklistKindStyle(item.kind);
                return (
                  <button
                    key={`drawer-checklist-${item.label}`}
                    onClick={item.onToggle}
                    disabled={item.disabled}
                    aria-label={item.ariaLabel}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 8,
                      padding: '6px 8px',
                      borderRadius: 8,
                      border: item.highlighted ? '1px solid var(--accent)' : '1px solid var(--border)',
                      background: item.done ? 'rgba(0,206,201,0.08)' : 'var(--surface)',
                      color: item.done ? 'var(--green)' : 'var(--text)',
                      fontSize: 11,
                      cursor: item.disabled ? 'not-allowed' : 'pointer',
                      opacity: item.disabled ? 0.6 : 1,
                      textAlign: 'left',
                      boxShadow: item.highlighted ? '0 0 0 1px rgba(116,185,255,0.18)' : 'none',
                    }}
                  >
                    <span style={{ fontWeight: 700 }}>{item.done ? 'Done' : 'Todo'}</span>
                    <span
                      style={{
                        padding: '2px 6px',
                        borderRadius: 999,
                        background: kindStyle.background,
                        color: kindStyle.color,
                        fontSize: 10,
                        fontWeight: 700,
                      }}
                    >
                      {item.kind}
                    </span>
                    <span>{item.label}</span>
                  </button>
                );
              })()
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
