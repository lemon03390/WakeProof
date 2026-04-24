// WakeProof — screen components
// Each screen fills the full device height edge-to-edge with warm
// gradient / ambient glow / breathing illustration. No flat black voids.

const { useState, useEffect } = React;

// ─── Design tokens
const WP = {
  cream50:  '#FEF8ED',
  cream100: '#FBEEDB',
  cream200: '#F5E3C7',
  cream300: '#EAD3AD',
  char950:  '#1A120C',
  char900:  '#2B1F17',
  char800:  '#3D2D22',
  char700:  '#554034',
  char500:  '#8A6B55',
  char300:  '#B89A82',
  orange:   '#FFA047',
  coral:    '#F54F4F',
  verified: '#4E8F47',
  attempted:'#E07A2E',
  warning:  '#E6B54A',
  danger:   '#C94A3A',
  gradient: 'linear-gradient(135deg, #FFA047 0%, #F54F4F 100%)',
  sunrise:  'linear-gradient(180deg, #1A120C 0%, #6E3824 45%, #F38B4D 85%, #FBEEDB 100%)',
  heroDark: 'linear-gradient(180deg, #1A120C 0%, #2B1F17 60%, #3D2D22 100%)',
  fontBody: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", system-ui, sans-serif',
  fontDisplay: '"Nunito", "SF Pro Rounded", -apple-system, BlinkMacSystemFont, system-ui, sans-serif',
};

// ─── Inject global keyframes once for ambient animations.
(function injectWPKeyframes() {
  if (typeof document === 'undefined') return;
  if (document.getElementById('wp-keyframes')) return;
  const s = document.createElement('style');
  s.id = 'wp-keyframes';
  s.textContent = `
    @keyframes wp-breathe {
      0%, 100% { opacity: 0.55; transform: scale(1); }
      50%      { opacity: 0.95; transform: scale(1.06); }
    }
    @keyframes wp-pulse-ring {
      0%   { opacity: 0.75; transform: scale(0.9); }
      70%  { opacity: 0;    transform: scale(1.6); }
      100% { opacity: 0;    transform: scale(1.6); }
    }
    @keyframes wp-drift {
      0%, 100% { transform: translateY(0); }
      50%      { transform: translateY(-10px); }
    }
  `;
  document.head.appendChild(s);
})();

// ─── Shared button
function WPButton({ variant = 'white', children, onClick, disabled }) {
  const [pressed, setPressed] = useState(false);
  const base = {
    width: '100%',
    height: variant === 'alarm' ? 60 : 52,
    borderRadius: variant === 'alarm' ? 999 : 14,
    fontFamily: WP.fontBody,
    fontWeight: variant === 'alarm' ? 700 : 600,
    fontSize: variant === 'alarm' ? 18 : 17,
    border: 'none',
    cursor: disabled ? 'not-allowed' : 'pointer',
    transition: 'opacity 120ms, transform 120ms',
    opacity: pressed ? 0.85 : (disabled ? 0.5 : 1),
    transform: pressed && variant === 'alarm' ? 'scale(0.98)' : 'scale(1)',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
  };
  const fills = {
    alarm:   { background: WP.gradient, color: WP.cream50, boxShadow: '0 8px 24px rgba(245,79,79,0.28)' },
    white:   { background: WP.cream50, color: WP.char900 },
    confirm: { background: WP.verified, color: WP.cream50 },
    muted:   { background: 'rgba(254,248,237,0.4)', color: WP.char900 },
    dark:    { background: WP.char900, color: WP.cream50 },
  };
  return (
    <button
      style={{ ...base, ...fills[variant] }}
      onPointerDown={() => setPressed(true)}
      onPointerUp={() => setPressed(false)}
      onPointerLeave={() => setPressed(false)}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}

// ─── Ambient-glow decorations (absolutely-positioned, pointer-events:none)

// Warm bottom glow — for dark hero screens that don't have their own
// full-bleed gradient. Gives the lower 45% of the screen a tied-to-icon warmth.
function BottomAmbientGlow({ intensity = 1, palette = 'coral' }) {
  const c1 = palette === 'coral'
    ? 'rgba(245,79,79,0.28)'
    : palette === 'sunrise'
      ? 'rgba(243,139,77,0.32)'
      : 'rgba(255,160,71,0.24)';
  const c2 = palette === 'coral'
    ? 'rgba(255,160,71,0.18)'
    : palette === 'sunrise'
      ? 'rgba(230,181,74,0.22)'
      : 'rgba(255,160,71,0.12)';
  return (
    <>
      <div style={{
        position: 'absolute', left: '50%', bottom: '-30%',
        width: '160%', height: '75%', transform: 'translateX(-50%)',
        background: `radial-gradient(ellipse at 50% 100%, ${c1} 0%, ${c2} 35%, transparent 70%)`,
        opacity: intensity, pointerEvents: 'none', zIndex: 0,
      }} />
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0, height: '3px',
        background: `linear-gradient(90deg, transparent 0%, ${c1} 50%, transparent 100%)`,
        opacity: 0.9, pointerEvents: 'none', zIndex: 1,
      }} />
    </>
  );
}

// Pulsing halo — for the alarm-ringing screen. Breathes at ~1.8s.
function RingingHalo() {
  return (
    <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', overflow: 'hidden', zIndex: 0 }}>
      {/* top halo behind time */}
      <div style={{
        position: 'absolute', left: '50%', top: '22%', width: 520, height: 520,
        transform: 'translate(-50%, -50%)',
        background: 'radial-gradient(circle, rgba(255,160,71,0.28) 0%, rgba(245,79,79,0.16) 35%, transparent 70%)',
        borderRadius: '50%',
        animation: 'wp-breathe 1.8s ease-in-out infinite',
      }} />
      {/* bottom beam */}
      <div style={{
        position: 'absolute', left: '50%', bottom: '-25%', width: '180%', height: '70%',
        transform: 'translateX(-50%)',
        background: 'radial-gradient(ellipse at 50% 100%, rgba(245,79,79,0.42) 0%, rgba(255,160,71,0.22) 30%, transparent 65%)',
        animation: 'wp-breathe 1.8s ease-in-out infinite 0.6s',
      }} />
      {/* soft pulse rings at bottom */}
      <div style={{
        position: 'absolute', left: '50%', bottom: '18%',
        width: 200, height: 200, marginLeft: -100, marginBottom: -100,
        borderRadius: '50%', border: '1px solid rgba(255,160,71,0.6)',
        animation: 'wp-pulse-ring 2.4s ease-out infinite',
      }} />
      <div style={{
        position: 'absolute', left: '50%', bottom: '18%',
        width: 200, height: 200, marginLeft: -100, marginBottom: -100,
        borderRadius: '50%', border: '1px solid rgba(245,79,79,0.5)',
        animation: 'wp-pulse-ring 2.4s ease-out infinite 1.2s',
      }} />
    </div>
  );
}

// Dawn horizon — for the morning-briefing screen. Warm horizontal band
// that blooms across the lower half, paired with the sunrise gradient bg.
function DawnHorizon() {
  return (
    <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', overflow: 'hidden', zIndex: 0 }}>
      <div style={{
        position: 'absolute', left: '-20%', right: '-20%', bottom: '26%',
        height: 120,
        background: 'linear-gradient(180deg, transparent 0%, rgba(255,213,160,0.55) 50%, transparent 100%)',
        filter: 'blur(22px)',
      }} />
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0, height: '35%',
        background: 'linear-gradient(180deg, rgba(251,238,219,0) 0%, rgba(251,238,219,0.55) 70%, rgba(251,238,219,0.85) 100%)',
      }} />
      {/* sun sliver */}
      <div style={{
        position: 'absolute', left: '50%', bottom: '30%',
        width: 340, height: 340, marginLeft: -170, marginBottom: -170,
        borderRadius: '50%',
        background: 'radial-gradient(circle, rgba(255,200,140,0.5) 0%, rgba(255,160,71,0.25) 40%, transparent 70%)',
        animation: 'wp-breathe 5s ease-in-out infinite',
      }} />
    </div>
  );
}

// ─── 04 Alarm scheduler (home) — already fills; kept as-is
function AlarmSchedulerScreen({ onSimulateAlarm }) {
  const [alarmOn, setAlarmOn] = useState(true);
  const [note, setNote] = useState('Run 5k, then shower before the standup');

  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: WP.cream100, overflow: 'hidden',
    fontFamily: WP.fontBody, color: WP.char900, position: 'relative',
  };
  const headerStyle = {
    padding: '8px 20px 18px', display: 'flex',
    alignItems: 'baseline', justifyContent: 'space-between',
    position: 'relative', zIndex: 2,
  };
  const titleStyle = {
    fontFamily: WP.fontDisplay, fontSize: 34, fontWeight: 800,
    letterSpacing: '-0.015em', color: WP.char900,
  };
  const bodyStyle = { flex: 1, overflowY: 'auto', padding: '0 20px 24px', position: 'relative', zIndex: 2 };
  const heroCardStyle = {
    background: WP.cream50, borderRadius: 28, padding: '22px 22px 20px',
    boxShadow: '0 4px 14px rgba(43,31,23,0.06)',
    display: 'flex', flexDirection: 'column', gap: 14,
  };
  const timeStyle = {
    fontFamily: WP.fontDisplay, fontSize: 64, fontWeight: 800,
    lineHeight: 1, fontVariantNumeric: 'tabular-nums',
    background: WP.gradient, WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
    backgroundClip: 'text', color: 'transparent',
  };
  const streakPillStyle = {
    display: 'inline-flex', alignItems: 'center', gap: 8,
    padding: '6px 14px', borderRadius: 999,
    background: WP.cream200, color: WP.char900, fontSize: 13, fontWeight: 600,
  };
  const toggleStyle = (on) => ({
    width: 52, height: 32, borderRadius: 999,
    background: on ? WP.gradient : 'rgba(43,31,23,0.2)',
    position: 'relative', cursor: 'pointer',
    boxShadow: on ? '0 4px 12px rgba(245,79,79,0.28)' : 'none',
  });
  const knobStyle = (on) => ({
    position: 'absolute', top: 2, [on ? 'right' : 'left']: 2,
    width: 28, height: 28, background: WP.cream50, borderRadius: '50%',
    boxShadow: '0 2px 4px rgba(0,0,0,0.15)',
  });
  const sectionLabel = {
    fontSize: 12, fontWeight: 700, letterSpacing: '0.08em',
    textTransform: 'uppercase', color: WP.char500,
    marginTop: 22, marginBottom: 8, padding: '0 4px',
  };
  const cardStyle = { background: WP.cream50, borderRadius: 20, overflow: 'hidden' };
  const rowStyle = {
    padding: '16px 18px', display: 'flex', alignItems: 'center',
    justifyContent: 'space-between', gap: 12,
  };
  const rowDivider = { height: 1, background: 'rgba(43,31,23,0.06)', marginLeft: 18 };
  const rowLabel = { fontSize: 16, fontWeight: 500, color: WP.char900 };
  const rowDetail = { fontSize: 15, color: WP.char500 };
  const noteFieldStyle = {
    width: '100%', boxSizing: 'border-box',
    padding: '14px 18px', border: 'none', outline: 'none',
    background: WP.cream50, fontSize: 16, fontFamily: WP.fontBody,
    color: WP.char900, borderRadius: 20, resize: 'none',
  };
  const framingStyle = {
    marginTop: 24, padding: '18px 22px',
    fontSize: 14, lineHeight: 1.55,
    color: WP.char500, textAlign: 'center', fontStyle: 'italic',
  };

  return (
    <div style={screenStyle}>
      {/* Warm cream-to-apricot radial at the top gives the home a faint sunrise tie-in */}
      <div style={{ position: 'absolute', left: '50%', top: '-10%', width: '160%', height: '55%', transform: 'translateX(-50%)', background: 'radial-gradient(ellipse at 50% 0%, rgba(255,200,140,0.35) 0%, rgba(255,160,71,0.15) 35%, transparent 70%)', pointerEvents: 'none', zIndex: 1 }} />

      <div style={headerStyle}>
        <div style={titleStyle}>WakeProof</div>
        <div style={{ fontSize: 15, color: WP.char500 }}>Wed · Apr 22</div>
      </div>

      <div style={bodyStyle}>
        <div style={heroCardStyle}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 14, justifyContent: 'space-between' }}>
            <div>
              <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: '0.08em', textTransform: 'uppercase', color: WP.char500, marginBottom: 4 }}>Next ring</div>
              <div style={timeStyle}>6:30</div>
            </div>
            <div style={streakPillStyle}>
              <span style={{ fontFamily: WP.fontDisplay, fontWeight: 800, fontSize: 16 }}>4</span>
              <span>day streak</span>
            </div>
          </div>
          <div style={{ fontSize: 14, color: WP.char500, lineHeight: 1.45 }}>
            Tomorrow you meet yourself at <strong style={{ color: WP.char900, fontWeight: 600 }}>the kitchen counter</strong>. Best: 11 days.
          </div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 0 0', borderTop: '1px solid rgba(43,31,23,0.08)' }}>
            <div style={rowLabel}>Alarm enabled</div>
            <div style={toggleStyle(alarmOn)} onClick={() => setAlarmOn(!alarmOn)}>
              <div style={knobStyle(alarmOn)} />
            </div>
          </div>
        </div>

        <div style={sectionLabel}>Wake window</div>
        <div style={cardStyle}>
          <div style={rowStyle}><div style={rowLabel}>Start</div><div style={{ ...rowDetail, color: WP.char900, fontWeight: 500 }}>6:30 AM ›</div></div>
          <div style={rowDivider} />
          <div style={rowStyle}><div style={rowLabel}>Sound</div><div style={rowDetail}>Daybreak ›</div></div>
        </div>

        <div style={sectionLabel}>First thing tomorrow</div>
        <div style={cardStyle}>
          <textarea style={noteFieldStyle} value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
        </div>
        <div style={{ fontSize: 12, color: WP.char500, padding: '6px 4px 0', textAlign: 'right' }}>{note.length}/140</div>

        <div style={sectionLabel}>Streak</div>
        <div style={cardStyle}>
          <div style={{ ...rowStyle, cursor: 'pointer' }}><div style={rowLabel}>View streak calendar</div><div style={{ color: WP.char300, fontSize: 18 }}>›</div></div>
          <div style={rowDivider} />
          <div style={{ ...rowStyle, cursor: 'pointer' }}><div style={rowLabel}>Your commitment</div><div style={{ color: WP.char300, fontSize: 18 }}>›</div></div>
        </div>

        <div style={framingStyle}>
          Apple Clock doesn't know you.<br/>WakeProof has 12 of your mornings.
        </div>

        {onSimulateAlarm && (
          <div style={{ marginTop: 16 }}>
            <WPButton variant="white" onClick={onSimulateAlarm}>Simulate alarm ring</WPButton>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── 05 Alarm ringing — full-bleed warm atmosphere, breathing halo
function AlarmRingingScreen({ onProve }) {
  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: 'linear-gradient(180deg, #1A120C 0%, #3D1F12 40%, #6E3824 75%, #8F3E1E 100%)',
    color: WP.cream50, position: 'relative', overflow: 'hidden',
    fontFamily: WP.fontBody,
  };
  const contentStyle = {
    flex: 1, display: 'flex', flexDirection: 'column',
    justifyContent: 'center', gap: 28, padding: '40px 24px 0',
    position: 'relative', zIndex: 2,
  };
  const footerStyle = {
    padding: '0 24px 32px', position: 'relative', zIndex: 2,
    display: 'flex', flexDirection: 'column', gap: 14,
  };
  const timeStyle = {
    fontFamily: WP.fontDisplay, fontSize: 96, fontWeight: 800,
    lineHeight: 1, letterSpacing: '-0.02em',
    fontVariantNumeric: 'tabular-nums', textAlign: 'center',
    background: WP.gradient, WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
    backgroundClip: 'text', color: 'transparent',
    filter: 'drop-shadow(0 4px 24px rgba(255,160,71,0.45))',
  };
  const subStyle = { fontSize: 22, fontWeight: 500, textAlign: 'center', color: WP.cream50, marginTop: 8 };
  const meetStyle = { fontSize: 18, textAlign: 'center', color: 'rgba(251,238,219,0.88)', lineHeight: 1.4, padding: '0 20px' };
  return (
    <div style={screenStyle}>
      <RingingHalo />
      <div style={contentStyle}>
        <div>
          <div style={timeStyle}>6:30</div>
          <div style={subStyle}>Wednesday</div>
        </div>
        <div style={meetStyle}>
          Meet yourself at <strong style={{ color: WP.cream50, fontWeight: 700 }}>the kitchen counter</strong>.
        </div>
      </div>
      <div style={footerStyle}>
        <div style={{ textAlign: 'center' }}>
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '8px 16px', borderRadius: 999, background: 'rgba(26,18,12,0.45)', backdropFilter: 'blur(8px)', border: '1px solid rgba(255,160,71,0.25)', color: 'rgba(251,238,219,0.9)', fontSize: 13, fontWeight: 500, letterSpacing: '0.02em' }}>
            <span style={{ width: 8, height: 8, borderRadius: '50%', background: WP.coral, boxShadow: '0 0 12px rgba(245,79,79,0.8)', animation: 'wp-breathe 1.4s ease-in-out infinite' }} />
            Cannot be dismissed — only verified
          </div>
        </div>
        <WPButton variant="alarm" onClick={onProve}>Prove you're awake</WPButton>
      </div>
    </div>
  );
}

// ─── 06 Morning briefing — sunrise full-bleed with dawn horizon
function MorningBriefingScreen({ onContinue }) {
  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: WP.sunrise, color: WP.cream50,
    padding: '56px 24px 28px', fontFamily: WP.fontBody,
    position: 'relative', overflow: 'hidden',
  };
  const contentStyle = { flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', position: 'relative', zIndex: 2 };
  const eyebrowStyle = { fontSize: 12, fontWeight: 700, letterSpacing: '0.12em', textTransform: 'uppercase', color: 'rgba(251,238,219,0.78)', textAlign: 'center' };
  const timeStyle = {
    fontFamily: WP.fontDisplay, fontSize: 72, fontWeight: 800,
    lineHeight: 1, letterSpacing: '-0.02em',
    fontVariantNumeric: 'tabular-nums',
    textAlign: 'center', color: WP.cream50, marginTop: 8,
    textShadow: '0 4px 24px rgba(26,18,12,0.3)',
  };
  const h1Style = {
    fontFamily: WP.fontDisplay, fontSize: 38, fontWeight: 800,
    lineHeight: 1.1, letterSpacing: '-0.015em',
    color: WP.cream50, textAlign: 'center', marginTop: 24,
  };
  const commitmentCardStyle = {
    marginTop: 22, padding: '18px 22px',
    background: 'rgba(26,18,12,0.32)',
    backdropFilter: 'blur(10px)',
    border: '1px solid rgba(251,238,219,0.16)',
    borderRadius: 20,
  };
  const commitLabel = { fontSize: 11, fontWeight: 700, letterSpacing: '0.10em', textTransform: 'uppercase', color: 'rgba(251,238,219,0.72)', marginBottom: 6 };
  const commitText = { fontSize: 19, fontWeight: 600, lineHeight: 1.3, color: WP.cream50 };

  const footerStyle = { position: 'relative', zIndex: 2, display: 'flex', flexDirection: 'column', gap: 16 };
  return (
    <div style={screenStyle}>
      <DawnHorizon />
      <div style={contentStyle}>
        <div style={eyebrowStyle}>Verified · 4-day streak</div>
        <div style={timeStyle}>7:02</div>
        <div style={h1Style}>
          You showed up.<br/>Claude saw you at the kitchen.
        </div>
        <div style={commitmentCardStyle}>
          <div style={commitLabel}>You told yourself last night</div>
          <div style={commitText}>Run 5k, then shower before the standup.</div>
        </div>
      </div>
      <div style={footerStyle}>
        <WPButton variant="dark" onClick={onContinue}>Begin the day</WPButton>
        <div style={{ textAlign: 'center', fontSize: 13, color: 'rgba(43,31,23,0.62)', lineHeight: 1.5, padding: '0 16px', fontStyle: 'italic' }}>
          Third Monday in a row you've been up before 7:10 — the hard days are getting easier.
        </div>
      </div>
    </div>
  );
}

// ─── 01 Welcome — warm bottom glow, no flat void
function OnboardingWelcomeScreen({ onBegin }) {
  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: 'linear-gradient(180deg, #1A120C 0%, #2B1F17 55%, #3D2317 100%)',
    color: WP.cream50, padding: '56px 28px 28px', fontFamily: WP.fontBody,
    position: 'relative', overflow: 'hidden',
  };
  const brandRow = { display: 'flex', alignItems: 'center', gap: 12, position: 'relative', zIndex: 2 };
  const wordmark = {
    fontFamily: WP.fontDisplay, fontSize: 24, fontWeight: 800,
    letterSpacing: '-0.015em',
    background: WP.gradient, WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent',
    backgroundClip: 'text', color: 'transparent',
  };
  const h1Style = {
    fontFamily: WP.fontDisplay, fontSize: 42, fontWeight: 800,
    lineHeight: 1.05, letterSpacing: '-0.02em', color: WP.cream50,
  };
  const bodyStyle = { fontSize: 17, lineHeight: 1.55, color: 'rgba(251,238,219,0.82)' };
  return (
    <div style={screenStyle}>
      <BottomAmbientGlow palette="coral" />
      <div style={brandRow}>
        <img src="../../assets/icon_180.png" alt="" width={36} height={36} style={{ borderRadius: 8 }} />
        <div style={wordmark}>WakeProof</div>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 18, position: 'relative', zIndex: 2 }}>
        <div style={h1Style}>An alarm your<br/>future self can't<br/>cheat.</div>
        <div style={bodyStyle}>
          You'll set a contract with yourself: tomorrow morning, you will be out of bed at your designated wake-location. The only way to silence the alarm is to prove it. Claude Opus 4.7 is the witness.
        </div>
      </div>
      <div style={{ position: 'relative', zIndex: 2 }}>
        <WPButton variant="white" onClick={onBegin}>Begin</WPButton>
      </div>
    </div>
  );
}

// ─── 02 Camera permission — warm bottom glow
function OnboardingCameraScreen({ onEnable }) {
  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: 'linear-gradient(180deg, #1A120C 0%, #2B1F17 55%, #3D2317 100%)',
    color: WP.cream50, padding: '56px 28px 28px', fontFamily: WP.fontBody,
    position: 'relative', overflow: 'hidden',
  };
  const iconCircle = {
    width: 76, height: 76, borderRadius: 22,
    background: WP.gradient, display: 'flex',
    alignItems: 'center', justifyContent: 'center',
    boxShadow: '0 10px 40px rgba(245,79,79,0.45)',
    animation: 'wp-drift 4s ease-in-out infinite',
  };
  const h1Style = { fontFamily: WP.fontDisplay, fontSize: 34, fontWeight: 800, lineHeight: 1.1, letterSpacing: '-0.015em', color: WP.cream50, marginTop: 32 };
  const bodyStyle = { fontSize: 17, lineHeight: 1.55, color: 'rgba(251,238,219,0.82)', marginTop: 14 };
  return (
    <div style={screenStyle}>
      <BottomAmbientGlow palette="coral" />
      <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: '0.10em', textTransform: 'uppercase', color: 'rgba(251,238,219,0.55)', position: 'relative', zIndex: 2 }}>Step 2 of 5</div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', position: 'relative', zIndex: 2 }}>
        <div style={iconCircle}>
          <svg width="38" height="38" viewBox="0 0 24 24" fill="none" stroke={WP.cream50} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/></svg>
        </div>
        <div style={h1Style}>The contract needs a witness.</div>
        <div style={bodyStyle}>
          When your alarm rings, you'll take one live photo at your designated wake-location. Claude Opus 4.7 checks you're actually there and actually awake. No photos leave your device except that single verification call.
        </div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, position: 'relative', zIndex: 2 }}>
        <WPButton variant="white" onClick={onEnable}>Enable camera</WPButton>
        <button style={{ background: 'transparent', border: 'none', color: 'rgba(251,238,219,0.7)', fontSize: 15, fontFamily: WP.fontBody, padding: '10px', cursor: 'pointer' }}>Why we need this</button>
      </div>
    </div>
  );
}

// ─── 03 Baseline photo — warm bottom glow
function BaselinePhotoScreen({ onSave }) {
  const [label, setLabel] = useState('Kitchen counter');
  const [captured, setCaptured] = useState(true);
  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: 'linear-gradient(180deg, #1A120C 0%, #2B1F17 55%, #3D2317 100%)',
    color: WP.cream50, padding: '56px 24px 28px', fontFamily: WP.fontBody,
    position: 'relative', overflow: 'hidden',
  };
  const h1Style = { fontFamily: WP.fontDisplay, fontSize: 30, fontWeight: 800, lineHeight: 1.15, letterSpacing: '-0.015em', color: WP.cream50, textAlign: 'center' };
  const bodyStyle = { fontSize: 15, lineHeight: 1.5, color: 'rgba(251,238,219,0.82)', textAlign: 'center', marginTop: 12, padding: '0 8px' };
  const previewStyle = {
    marginTop: 24, width: '100%', aspectRatio: '3/2',
    borderRadius: 18, background: 'linear-gradient(140deg, #2b1f17 0%, #4a3526 50%, #7a5a42 100%)',
    position: 'relative', overflow: 'hidden',
    border: '1px solid rgba(251,238,219,0.14)',
    boxShadow: '0 12px 40px rgba(26,18,12,0.45)',
  };
  const fakeScene = (
    <>
      <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: '45%', background: 'linear-gradient(180deg, transparent, rgba(26,18,12,0.6))' }}/>
      <div style={{ position: 'absolute', left: '10%', top: '20%', width: '24%', height: '35%', background: 'rgba(251,238,219,0.15)', borderRadius: 10 }}/>
      <div style={{ position: 'absolute', right: '12%', top: '25%', width: '16%', height: '28%', background: 'rgba(245,79,79,0.28)', borderRadius: 10 }}/>
      <div style={{ position: 'absolute', left: '15%', bottom: '14%', right: '15%', height: 12, background: 'rgba(251,238,219,0.25)', borderRadius: 2 }}/>
      <div style={{ position: 'absolute', right: 12, bottom: 12, padding: '4px 10px', background: 'rgba(26,18,12,0.55)', color: WP.cream50, fontSize: 11, fontWeight: 600, borderRadius: 999, letterSpacing: '0.05em' }}>CAPTURED</div>
    </>
  );
  const inputStyle = {
    width: '100%', boxSizing: 'border-box',
    marginTop: 18, padding: '14px 16px',
    background: 'rgba(251,238,219,0.08)',
    border: '1px solid rgba(251,238,219,0.20)',
    borderRadius: 12, color: WP.cream50,
    fontSize: 17, fontFamily: WP.fontBody, outline: 'none',
  };
  return (
    <div style={screenStyle}>
      <BottomAmbientGlow palette="warm" />
      <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: '0.10em', textTransform: 'uppercase', color: 'rgba(251,238,219,0.55)', textAlign: 'center', position: 'relative', zIndex: 2 }}>Step 5 of 5</div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', position: 'relative', zIndex: 2 }}>
        <div style={h1Style}>Your wake-location</div>
        <div style={bodyStyle}>
          Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk.
        </div>
        <div style={previewStyle}>{captured && fakeScene}</div>
        <input style={inputStyle} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Label this spot" />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, position: 'relative', zIndex: 2 }}>
        <WPButton variant="confirm" onClick={() => onSave && onSave(label)} disabled={!label.trim()}>Save &amp; continue</WPButton>
        <button onClick={() => setCaptured(false)} style={{ background: 'transparent', border: 'none', color: 'rgba(251,238,219,0.7)', fontSize: 15, fontFamily: WP.fontBody, padding: '6px', cursor: 'pointer' }}>Retake</button>
      </div>
    </div>
  );
}

// ─── 07 Disable challenge — warm bottom glow, stricter tone
function DisableChallengeScreen({ onProve, onCancel }) {
  const screenStyle = {
    height: '100%', display: 'flex', flexDirection: 'column',
    background: 'linear-gradient(180deg, #1A120C 0%, #2B1F17 55%, #3D2317 100%)',
    color: WP.cream50, padding: '60px 28px 28px', fontFamily: WP.fontBody,
    position: 'relative', overflow: 'hidden',
  };
  const iconCircle = {
    width: 80, height: 80, borderRadius: '50%',
    background: 'rgba(251,238,219,0.06)',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    border: '1px solid rgba(251,238,219,0.16)', margin: '0 auto',
    boxShadow: '0 0 40px rgba(255,160,71,0.2)',
  };
  return (
    <div style={screenStyle}>
      <BottomAmbientGlow palette="coral" intensity={0.8} />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 22, position: 'relative', zIndex: 2 }}>
        <div style={iconCircle}>
          <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke={WP.cream50} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M12 2L3 7v6c0 5 3.5 9.5 9 11 5.5-1.5 9-6 9-11V7l-9-5z"/><path d="M9 12l2 2 4-4"/></svg>
        </div>
        <div style={{ fontFamily: WP.fontDisplay, fontSize: 30, fontWeight: 800, lineHeight: 1.15, letterSpacing: '-0.015em', textAlign: 'center' }}>
          Prove you're awake<br/>to disable.
        </div>
        <div style={{ fontSize: 16, lineHeight: 1.5, color: 'rgba(251,238,219,0.82)', textAlign: 'center', padding: '0 10px' }}>
          Meet yourself at <strong style={{ color: WP.cream50, fontWeight: 700 }}>the kitchen counter</strong> first — same as a morning ring.
        </div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, position: 'relative', zIndex: 2 }}>
        <WPButton variant="alarm" onClick={onProve}>Prove you're awake → disable</WPButton>
        <button onClick={onCancel} style={{ background: 'transparent', border: 'none', color: 'rgba(251,238,219,0.7)', fontSize: 15, fontFamily: WP.fontBody, padding: '10px', cursor: 'pointer' }}>Cancel</button>
      </div>
    </div>
  );
}

Object.assign(window, {
  WP, WPButton,
  AlarmSchedulerScreen,
  AlarmRingingScreen,
  MorningBriefingScreen,
  OnboardingWelcomeScreen,
  OnboardingCameraScreen,
  BaselinePhotoScreen,
  DisableChallengeScreen,
});
