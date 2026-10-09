# Windows lyric motion

The taskbar keeps its transparent HWND fixed. A TranslateTransform moves the
incoming text, measured in WPF DIPs without trimming or horizontal scaling.
Its target is the reserved tray boundary minus the current shaped text width.
Windows retains its 6 DIP optical gap and bundled Pretendard JP Light 300.

## Empirical source

The supplied handoff measured macOS 27.2 build 26B5101f on a Retina 2x,
120Hz display with Reduce Motion disabled. Its source main commit is
8ecd9755f94a7e41990a1d3f1ed17e76274c79c7.
NativeStatusSpring.cs reference SHA-256:
d081ec81f753de940001037264d32f9832f13e54b24de9ee2c7c6ac39a77d01b.
native-model-results.json SHA-256:
78d9b49777af098d34aa35bc54253e31e956a25c03ff3e437256dec13a2d499f.
verification-result.json SHA-256:
4a396907d53639ebe3289249a3561c44918ced6f8d6606ab650dc748a044127e.

20 received files were reconstructed and checked against their exact byte lengths
and hashes; the original C# reference was compiled and executed unmodified.
The source ZIP and raw CSV captures were not received. Original fit error
statistics are supplied evidence, not locally reproduced measurements.

## Model

Response 0.5 seconds is a natural period, not a fixed duration.
Damping is 0.8; A = 3.2π and B = 2.4π:

    p(t) = 1 - exp(-A*t) * (cos(B*t) + 4/3*sin(B*t))

First target crossing is approximately 331.3ms, and the peak at 416.667ms
overshoots by 1.516462%. Two equal contributions stop separately, with
displacement/velocity thresholds 0.5 DIP and 0.5 DIP/s, then 0.25 DIP and
0.25 DIP/s. Both conditions must hold. These parts and thresholds are an
empirical model; they are not claimed to be recovered Apple implementation code.

Settlement is checked on 120Hz model steps. Analytic interpolation provides
positions between those steps for other rendering rates. On retarget, each
contribution commits its current fractional time before taking the new target,
preserving both position and velocity. The response is evaluated with those
initial conditions; velocity is not reset and the progress is not clamped.

The new text and its shaped width change immediately at the current left position.
An expanding line can temporarily overlap notification icons. Equal targets
do not restart the spring; duplicate text does not restart the fade.
Text width is fractional so measurement does not introduce integer-DIP jumps.

Windows fades are an independent option: old text fades out in 120ms,
new text fades in over 180ms. These timings are Windows policy and have not
been measured as macOS behavior. Disabling the option, system animation
disablement, hiding the taskbar display, or moving its anchor snaps motion.

## Verification

SurfLyrics.Tests contains 49 source report amplitude/settling vectors and
independent equations for their sampled positions. Additional checks cover
overshoot, retargeting at 120/250/400ms, fractional retargeting, duplicate targets,
60/120/144Hz sampling consistency, snap cancellation and invalid elapsed time.
The 113 Windows checks and 29 JavaScript checks passed.

A real WPF probe used the bundled 300 glyph face on the primary 96 DPI/144Hz
display. Four transitions included growth, shrinkage, a 1280.4 DIP line and
Japanese text. HWND geometry stayed fixed and the entire line remained untrimmed.
Moving frames had median callback intervals of 6.93–6.95ms (104–116 intermediate
samples per transition). The probe also verified interrupted transitions at
120/250/400ms, duplicate suppression, fade-off snapping, hide/restore and
WindowFromPoint passing through visible glyphs to another process.

The original reference compiled and produced final position 129, velocity zero
and peak 130.95623596252653 in the 129-point example.
The automated comparison covers other sampling rates; other DPI/refresh
configurations were not physically exercised. Rendering callback cadence is
not a guarantee of presentation cadence.

## Final recheck limitations

A later full probe failed its minimum nine intermediate frame requirement:
growth yielded six moving frames, with long callback gaps around 262ms.
A control using an ordinary visible-X WPF DoubleAnimation also showed
247–263ms gaps during its movement. Attaching a constant Y clock to the glyph
did not change the result and was reverted. The exact cause was not identified;
the first successful 144Hz record is not a guarantee of the final environment.

A separate final functional probe passed text replacement, equal-width Japanese
replacement without movement, duplicate suppression, interruptions at
120/250/400ms with retained velocity and eventual settlement, full text and
temporary overlap, constant HWND, glyph click-through, fade-off and hide/restore.
It explicitly did not certify cadence or the deceleration frame-count threshold.
The failing full run remains recorded separately.

Final published-app diagnostics loaded WinUI settings and received 44 synchronized
LRCLIB lines with Spotify paused. Previous native menu/save smoke tests passed,
but the last tray recheck could not move the cursor. An attempted coordinate
message probe was rejected by automatic approval review because it could affect
an unrelated window; it was not executed. No final tray input pass is claimed.
