; LocalDNS NSIS installer hooks — helper service lifecycle.
; The installer runs elevated (perMachine): this is the user's one-time,
; visible privilege event. The service itself is demand-start; no privileged
; process runs routinely.

!macro NSIS_HOOK_POSTINSTALL
  ; Re-create the service pointing at the freshly installed binary.
  nsExec::ExecToLog 'sc.exe stop localdns-helper'
  nsExec::ExecToLog 'sc.exe delete localdns-helper'
  nsExec::ExecToLog 'sc.exe create localdns-helper binPath= "$INSTDIR\localdns-helper.exe" start= demand DisplayName= "LocalDNS Helper"'
  ; Default service DACL + SERVICE_START (RP) for interactive users, so the
  ; unelevated app can demand-start it before a sync.
  nsExec::ExecToLog 'sc.exe sdset localdns-helper "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPLOCRRC;;;IU)(A;;CCLCSWRPLOCRRC;;;SU)"'
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  ; Remove our NRPT rules (binary runs elevated here), then drop the service.
  nsExec::ExecToLog '"$INSTDIR\localdns-helper.exe" --unregister-all'
  nsExec::ExecToLog 'sc.exe stop localdns-helper'
  nsExec::ExecToLog 'sc.exe delete localdns-helper'
!macroend
