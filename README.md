# Air Volume

Air Volume è una menubar app per macOS che rileva in rete i device compatibili tramite broadcast UDP e ne controlla il volume master via WebSocket. L'applicazione è pensata per scenari in cui il volume di un dispositivo AirPlay (o di un bridge personalizzato) deve essere tenuto sincronizzato o governato da un Mac senza dover tenere finestra o app di terze parti in primo piano.

## Funzionalità principali
- Scoperta automatica via UDP (`255.255.255.255:4210`) dei dispositivi che annunciano il servizio `airvol`.
- Connessione resiliente a WebSocket multipli con retry progressivo, heartbeat e watchdog integrati.
- Impostazione del volume di sistema macOS con soglia di variazione `setOnDelta` per evitare rumore su cambi minimi.
- Overlay nativo in stile Vision Pro (glass background) per notificare stato di connessione, variazioni volume e copy dei log.
- UI SwiftUI compatta con stato, device corrente, storico log e tools veloci (es. copia log).
- Supporto a forzature via variabili d'ambiente (`AIRVOL_IP`, `AIRVOL_WS_PORT`, `AIRVOL_NAME`).

## Architettura in breve
- **`AirVolumeService`**: motore principale (MainActor) che gestisce discovery, connessione WebSocket, watchdog/heartbeat, parsing payload volume e interazione con l'overlay.
- **`UdpDiscovery`**: wrapper di socket BSD per inviare pacchetti `discover` periodici e ricevere `announce` / `response`. Effettua parsing del payload JSON e seleziona il target.
- **`VolumeController`**: invoca `osascript` per impostare il volume output di macOS e conserva l'ultimo valore applicato.
- **`OverlayNotificationCenter`**: gestisce la finestra overlay sempre in primo piano, con animazioni e stile coerente con macOS 14+.
- **`AppDelegate` / `MainWindowCoordinator`**: inizializzano la status bar item, gestiscono l'unica finestra SwiftUI e impediscono la chiusura accidentale dell'applicazione.

## Requisiti
- macOS 14 Sonoma o successivo (richiesto per il glass effect e le API usate).
- Xcode 15 (o Swift 5.9 toolchain equivalente).
- Un device/bridge in rete locale che implementi il protocollo `airvol` (vedi sotto) e offra un endpoint WebSocket.

## Configurazione del device remoto
I dispositivi devono rispondere a broadcast UDP su `255.255.255.255:4210` inviando JSON con struttura simile:

```json
{
  "service": "airvol",
  "type": "announce",
  "name": "Studio Speaker",
  "ip": "192.168.1.120",
  "ws_port": 81,
  "ws_path": "/ws"
}
```

Il canale WebSocket deve inviare payload JSON contenenti almeno una delle seguenti chiavi:

- `percent`, `pct`, `volume_percent` (numero 0-100 o stringa convertibile).
- `raw`: valore 0-4095 che verrà normalizzato internamente a 0-100.

Il client invia un heartbeat (`{"hb":1}`) ogni 5 secondi. Se non vengono ricevuti payload applicativi per 12 secondi, la connessione viene terminata e riavviata.

## Setup e avvio
1. Clona il repository e apri `Air Volume.xcodeproj` con Xcode.
2. Seleziona il target "Air Volume" e imposta un team se necessario per i permessi di automation (AppleScript volume).
3. Compila ed esegui. L'app vive nella menu bar: usa l'icona `speaker.wave.2.fill` per riaprire / chiudere la finestra dell'interfaccia.

### Variabili d'ambiente opzionali
Aggiungi le seguenti chiavi allo schema di esecuzione (Edit Scheme > Arguments > Environment Variables) per forzare la connessione:

- `AIRVOL_IP`: IP del dispositivo da usare, ignorando la discovery broadcast.
- `AIRVOL_WS_PORT`: porta WebSocket da preferire (default annuncio).
- `AIRVOL_NAME`: nome da confrontare con `announce` per filtrare i dispositivi.

## Debug e troubleshooting
- Se il dispositivo non compare, verifica che il broadcast UDP sia consentito dalla rete (router / firewall) e che il device risponda con `service: "airvol"`.
- Usa il pulsante "Copia" nella UI per portare l'ultimo log (max 200 righe) in clipboard e allegarlo a eventuali segnalazioni.
- Per test locali senza discovery, esporta `AIRVOL_IP` e fai partire un semplice server WebSocket di test che invii valori di volume.
- Ricorda che l'app imposta il volume di sistema del Mac via `osascript`: se non vedi cambiamenti, controlla permessi di Automazione / Accessibilità nelle Preferenze di Sistema.

## Struttura del repository
- `Air Volume/` contiene il codice sorgente SwiftUI, il servizio di discovery, l'overlay e gli asset.
- `Air Volume.xcodeproj/` è il progetto Xcode.
- `Assets.xcassets` ospita icone e risorse UI.

## Contributi
- Apri una issue con descrizione del problema/proposta prima di inviare una pull request.
- Per modifiche funzionali significative, includi screenshot o registrazioni dell'overlay per facilitare la review.

## Licenza
⚠️ Questo repository non include ancora un file di licenza. Aggiungi una licenza (es. MIT, Apache 2.0) prima di distribuire build pubbliche.
