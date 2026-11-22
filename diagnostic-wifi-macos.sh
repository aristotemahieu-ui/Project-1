#!/bin/bash
# =============================================================================
#  Diagnostic Wi-Fi pour macOS
#  - Lecture seule : ne modifie aucun réglage de ton Mac ni de ton routeur.
#  - Durée : environ 1 min 30 (dont ~20 s de test de débit).
#  - Usage :   bash diagnostic-wifi-macos.sh
#              bash diagnostic-wifi-macos.sh --complet   (ajoute « wdutil »,
#                                                         demande le mot de passe admin)
#  Le rapport est enregistré sur le Bureau (diagnostic-wifi-AAAAMMJJ-HHMMSS.txt).
#  Compatible avec le bash 3.2 fourni par macOS.
# =============================================================================

set -u
export LC_ALL=C   # sorties de commandes prévisibles (points décimaux, anglais)

COMPLET=0
[ "${1:-}" = "--complet" ] && COMPLET=1

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$HOME/Desktop"
[ -d "$DEST" ] || DEST="$HOME"
OUT="$DEST/diagnostic-wifi-$STAMP.txt"
TMP=$(mktemp -d /tmp/diagwifi.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

exec > >(tee "$OUT") 2>&1

titre() { printf '\n==================== %s ====================\n' "$1"; }
existe() { command -v "$1" >/dev/null 2>&1; }
# comparaison de nombres décimaux : num A op B  (op parmi < > <= >=)
num() { awk -v a="$1" -v b="$3" "BEGIN{exit !(a $2 b)}"; }

ALERTES="$TMP/alertes"; : > "$ALERTES"
OK="$TMP/ok"; : > "$OK"
alerte() { echo "  [!] $*" >> "$ALERTES"; }
bon()    { echo "  [ok] $*" >> "$OK"; }

echo "Diagnostic Wi-Fi — $(date)"
echo "Rapport : $OUT"

# -----------------------------------------------------------------------------
titre "1. Système"
sw_vers 2>/dev/null
sysctl -n hw.model 2>/dev/null

# -----------------------------------------------------------------------------
titre "2. Interface Wi-Fi"
IFACE=$(networksetup -listallhardwareports 2>/dev/null \
        | awk '/Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
IFACE=${IFACE:-en0}
echo "Interface : $IFACE"
networksetup -getairportpower "$IFACE" 2>/dev/null
SSID=$(ipconfig getsummary "$IFACE" 2>/dev/null | awk -F' : ' '/ SSID :/{print $2; exit}')
echo "Réseau (SSID) : ${SSID:-inconnu (macOS peut le masquer sans autorisation de localisation)}"
echo "Adresse IP : $(ipconfig getifaddr "$IFACE" 2>/dev/null || echo 'aucune')"

# Est-ce que le Mac utilise vraiment le Wi-Fi pour sortir ?
DEFIF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
echo "Interface de sortie par défaut : ${DEFIF:-?}"
[ -n "$DEFIF" ] && [ "$DEFIF" != "$IFACE" ] && \
  alerte "Le trafic ne passe pas par le Wi-Fi ($DEFIF) : VPN ou câble actif ? Les mesures ci-dessous peuvent ne pas refléter le Wi-Fi."

# -----------------------------------------------------------------------------
titre "3. Connexion Wi-Fi et réseaux voisins"
system_profiler SPAirPortDataType 2>/dev/null \
  | grep -v -i 'MAC Address' > "$TMP/sp.txt"
cat "$TMP/sp.txt"

# Extraction des infos de la connexion actuelle + liste des canaux voisins
awk '
  /Current Network Information:/ {sec="cur"; next}
  /Other Local Wi-Fi Networks:/  {sec="oth"; next}
  sec=="cur" && /PHY Mode:/        && !phy {sub(/.*PHY Mode: */,"");        print "PHY="$0; phy=1}
  sec=="cur" && /Channel:/         && !ch  {sub(/.*Channel: */,"");         print "CHAN="$0; ch=1}
  sec=="cur" && /Signal \/ Noise:/ && !sn  {sub(/.*Noise: */,"");           print "SN="$0;  sn=1}
  sec=="cur" && /Transmit Rate:/   && !tr  {sub(/.*Transmit Rate: */,"");   print "RATE="$0; tr=1}
  sec=="oth" && /Channel:/                 {sub(/.*Channel: */,"");         print "NEIGH="$0}
' "$TMP/sp.txt" > "$TMP/wifi.txt"

PHY=$(awk -F= '/^PHY=/{print $2}' "$TMP/wifi.txt")
CHAN=$(awk -F= '/^CHAN=/{print $2}' "$TMP/wifi.txt")          # ex : 36 (5GHz, 80MHz)
SN=$(awk -F= '/^SN=/{print $2}' "$TMP/wifi.txt")              # ex : -52 dBm / -92 dBm
RATE=$(awk -F= '/^RATE=/{print $2}' "$TMP/wifi.txt")
CHNUM=$(echo "$CHAN" | awk '{print $1+0}')
BANDE=$(echo "$CHAN" | grep -o '[0-9]GHz' | head -1)
LARG=$(echo "$CHAN" | grep -o '[0-9]*MHz' | head -1 | tr -d 'MHz')
RSSI=$(echo "$SN" | awk '{print $1+0}')
BRUIT=$(echo "$SN" | awk -F'/' '{print $2+0}')

# Option : wdutil donne des infos plus précises (nécessite sudo)
if [ $COMPLET -eq 1 ]; then
  titre "3b. wdutil info (sudo)"
  sudo wdutil info 2>&1 | grep -v -i -E 'MAC Address' | tee "$TMP/wdutil.txt"
  [ -z "$RSSI" ] || [ "$RSSI" = "0" ] && RSSI=$(awk -F: '/^ *RSSI/{print $2+0; exit}' "$TMP/wdutil.txt")
  [ -z "$BRUIT" ] || [ "$BRUIT" = "0" ] && BRUIT=$(awk -F: '/^ *Noise/{print $2+0; exit}' "$TMP/wdutil.txt")
  [ -z "$RATE" ] && RATE=$(awk -F: '/^ *Tx Rate/{print $2+0; exit}' "$TMP/wdutil.txt")
fi

# Analyse radio
if [ -n "$RSSI" ] && [ "$RSSI" != "0" ]; then
  if   num "$RSSI" ">=" -60; then bon "Signal correct ($RSSI dBm)."
  elif num "$RSSI" ">=" -70; then alerte "Signal moyen ($RSSI dBm) : rapproche le Mac du routeur ou dégage les obstacles (murs, meubles métalliques, aquarium, micro-ondes)."
  else alerte "Signal FAIBLE ($RSSI dBm) : c'est probablement la cause principale. Rapproche-toi du routeur, déplace-le en hauteur et au centre du logement, ou ajoute un répéteur / système maillé (mesh)."
  fi
  if [ -n "$BRUIT" ] && [ "$BRUIT" != "0" ]; then
    SNR=$((RSSI - BRUIT))
    if   [ $SNR -lt 20 ]; then alerte "Rapport signal/bruit mauvais ($SNR dB) : fortes interférences ou signal trop faible."
    elif [ $SNR -lt 25 ]; then alerte "Rapport signal/bruit moyen ($SNR dB)."
    else bon "Rapport signal/bruit correct ($SNR dB)."
    fi
  fi
else
  alerte "Impossible de lire le signal. Relance avec --complet, ou vérifie que le Wi-Fi est connecté."
fi

if [ "$BANDE" = "2GHz" ]; then
  alerte "Connecté en 2,4 GHz (canal $CHNUM) : bande lente et encombrée. Si ton routeur propose le 5 GHz, utilise-le (réseau séparé « _5G » ou activer « band steering »)."
elif [ -n "$BANDE" ]; then
  bon "Bande $BANDE (canal $CHNUM)."
fi
if [ "$BANDE" = "5GHz" ] && [ -n "$LARG" ] && [ "$LARG" -le 20 ] 2>/dev/null; then
  alerte "Largeur de canal de seulement ${LARG} MHz en 5 GHz : passe à 80 MHz dans les réglages du routeur si possible."
fi

case "$PHY" in
  *802.11b*|*802.11g*|*802.11a*) alerte "Norme Wi-Fi ancienne ($PHY) : routeur ou mode de compatibilité très lent." ;;
  *802.11n*) alerte "Norme Wi-Fi 4 ($PHY) : débit limité. Un routeur Wi-Fi 5/6 (802.11ac/ax) serait nettement plus rapide si ton Mac le supporte." ;;
  "") ;;
  *) bon "Norme Wi-Fi : $PHY." ;;
esac

if [ -n "$RATE" ]; then
  echo "Débit de liaison négocié : $RATE Mbps"
  if num "$RATE" "<" 100; then alerte "Débit de liaison bas ($RATE Mbps) entre le Mac et le routeur."; fi
fi

# Congestion : réseaux voisins sur le même canal (± 4 canaux en 2,4 GHz car ils se chevauchent)
if [ -n "$CHNUM" ] && [ "$CHNUM" != "0" ]; then
  NBVOIS=$(awk -F= -v c="$CHNUM" -v b="$BANDE" '
    /^NEIGH=/ { n=$2+0; band=$2; d=n-c; if(d<0)d=-d;
      if (b=="2GHz" && band ~ /2GHz/ && d<=4) k++;
      else if (b!="2GHz" && n==c) k++ }
    END{print k+0}' "$TMP/wifi.txt")
  NBTOT=$(grep -c '^NEIGH=' "$TMP/wifi.txt")
  echo "Réseaux voisins détectés : $NBTOT, dont $NBVOIS qui se chevauchent avec ton canal $CHNUM"
  echo "Occupation des canaux par les voisins :"
  awk -F= '/^NEIGH=/{split($2,a," "); print "   canal " a[1]}' "$TMP/wifi.txt" | sort | uniq -c | sort -rn | head -15
  if [ "$NBVOIS" -ge 5 ]; then
    alerte "Canal $CHNUM très encombré ($NBVOIS réseaux voisins dessus) : choisis un canal moins utilisé dans le routeur (en 2,4 GHz : 1, 6 ou 11 uniquement)."
  elif [ "$NBVOIS" -ge 3 ]; then
    alerte "Canal $CHNUM partagé avec $NBVOIS réseaux voisins : un canal moins occupé pourrait aider."
  else
    bon "Canal peu encombré ($NBVOIS voisin(s) dessus)."
  fi
fi

# -----------------------------------------------------------------------------
titre "4. Latence et pertes : routeur puis Internet (≈ 40 s)"
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
echo "Routeur (passerelle) : ${GW:-introuvable}"

mesure_ping() {   # $1 = cible, $2 = fichier
  ping -c 20 -q "$1" > "$2" 2>&1
  cat "$2"
}
stat_ping() {     # affiche "perte moyenne gigue"
  awk '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /%$/){l=$i; sub(/%/,"",l)}}
       /round-trip|rtt/{split($4,a,"/"); m=a[2]; j=a[4]}
       END{print (l==""?100:l), (m==""?-1:m), (j==""?-1:j)}' "$1"
}

if [ -n "$GW" ]; then
  echo "--- vers le routeur ($GW)"; mesure_ping "$GW" "$TMP/p_gw.txt"
fi
echo "--- vers Internet (1.1.1.1)"; mesure_ping 1.1.1.1 "$TMP/p_net.txt"

if [ -n "$GW" ]; then
  set -- $(stat_ping "$TMP/p_gw.txt");  GL=$1; GM=$2; GJ=$3
  set -- $(stat_ping "$TMP/p_net.txt"); NL=$1; NM=$2; NJ=$3
  echo "Routeur  : perte ${GL}%  moyenne ${GM} ms  gigue ${GJ} ms"
  echo "Internet : perte ${NL}%  moyenne ${NM} ms  gigue ${NJ} ms"
  WIFI_KO=0
  if num "$GL" ">" 1; then alerte "Pertes de paquets vers le routeur (${GL}%) : le lien Wi-Fi lui-même est instable."; WIFI_KO=1; fi
  if num "$GM" ">" 15; then alerte "Latence élevée vers le routeur (${GM} ms, normal < 5 ms) : Wi-Fi saturé, signal faible ou interférences."; WIFI_KO=1; fi
  if num "$GJ" ">" 10; then alerte "Latence irrégulière vers le routeur (gigue ${GJ} ms) : interférences ou autre appareil qui monopolise le Wi-Fi."; WIFI_KO=1; fi
  [ $WIFI_KO -eq 0 ] && bon "Lien Mac ↔ routeur stable (${GM} ms, ${GL}% de perte)."
  if [ $WIFI_KO -eq 0 ] && { num "$NL" ">" 1 || num "$NM" ">" 60; }; then
    alerte "Le Wi-Fi est bon mais la connexion Internet est lente/instable (${NM} ms, ${NL}% de perte) : le problème vient plutôt de la box/ligne ou du fournisseur d'accès. Redémarre la box ; si ça persiste, contacte ton FAI."
  fi
fi

# -----------------------------------------------------------------------------
titre "5. Résolution DNS"
echo "Serveurs DNS utilisés :"
scutil --dns 2>/dev/null | awk '/nameserver\[/{print "   "$3}' | sort -u
DNSMAX=0
for d in apple.com google.com wikipedia.org lemonde.fr; do
  t=$(dig +tries=1 +time=3 +noall +stats "$d" 2>/dev/null | awk '/Query time/{print $4}')
  echo "   $d : ${t:-échec} ms"
  [ -n "$t" ] && [ "$t" -gt "$DNSMAX" ] && DNSMAX=$t
  [ -z "$t" ] && DNSMAX=9999
done
if [ "$DNSMAX" -gt 150 ]; then
  alerte "DNS lent (jusqu'à $DNSMAX ms) : les pages mettent du temps à « démarrer ». Essaie un DNS comme 1.1.1.1 ou 9.9.9.9 (Réglages Système > Réseau > Wi-Fi > Détails > DNS)."
else
  bon "DNS rapide (max $DNSMAX ms)."
fi

# -----------------------------------------------------------------------------
titre "6. Débit et réactivité sous charge (≈ 20 s)"
if existe networkQuality; then
  networkQuality -v 2>&1 | tee "$TMP/nq.txt"
  DOWN=$(awk -F: '/Downlink capacity/{print $2+0; exit}' "$TMP/nq.txt")
  UP=$(awk -F: '/Uplink capacity/{print $2+0; exit}' "$TMP/nq.txt")
  RPM=$(grep -i 'Responsiveness' "$TMP/nq.txt" | grep -o '[0-9.]* RPM' | head -1 | awk '{print $1+0}')
  echo "Descendant : ${DOWN:-?} Mbps   Montant : ${UP:-?} Mbps   Réactivité : ${RPM:-?} RPM"
  if [ -n "$RPM" ] && num "$RPM" "<" 200; then
    alerte "Réactivité faible sous charge ($RPM RPM) = « bufferbloat » : dès qu'un appareil télécharge ou envoie, tout le reste rame. Active SQM/QoS sur le routeur si disponible, ou cherche qui sature la connexion."
  elif [ -n "$RPM" ]; then
    bon "Réactivité sous charge correcte ($RPM RPM)."
  fi
else
  echo "networkQuality indisponible (macOS 12 ou plus requis)."
fi

# -----------------------------------------------------------------------------
titre "7. Erreurs sur l'interface Wi-Fi"
netstat -I "$IFACE" 2>/dev/null | sed -E "s/([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}/(MAC masquée)/"
ERR=$(netstat -I "$IFACE" 2>/dev/null | awk 'NR==2{print $6+$8}')
PKTS=$(netstat -I "$IFACE" 2>/dev/null | awk 'NR==2{print $5+$7}')
if [ -n "$ERR" ] && [ -n "$PKTS" ] && [ "$PKTS" -gt 0 ]; then
  if num "$ERR" ">" "$(awk -v p="$PKTS" 'BEGIN{print p*0.001}')"; then
    alerte "Taux d'erreurs anormal sur l'interface Wi-Fi ($ERR erreurs / $PKTS paquets)."
  fi
fi

# -----------------------------------------------------------------------------
titre "8. Applications de ce Mac qui utilisent le réseau (sur 5 s)"
if existe nettop; then
  nettop -P -d -L 2 -s 5 -x -J bytes_in,bytes_out 2>/dev/null > "$TMP/nettop.txt"
  # 2e échantillon = trafic pendant les 5 s ; tri par octets reçus
  awk -F, 'NR>1 && $1=="" {s++} s>=1 && NF>=3 && $1!="" {print}' "$TMP/nettop.txt" \
    | sort -t, -k2 -rn | head -10 \
    | awk -F, '{printf "   %-40s reçu %10d o   envoyé %10d o\n", $1, $2, $3}'
  echo "(Si une application synchronise en masse — iCloud, Dropbox, mises à jour — elle peut saturer la connexion.)"
fi

# -----------------------------------------------------------------------------
titre "9. Appareils vus sur le réseau local"
if [ -n "${GW:-}" ]; then
  # Petit ping broadcast pour réveiller la table ARP (sans effet sur les appareils)
  BCAST=$(ifconfig "$IFACE" 2>/dev/null | awk '/broadcast/{print $NF; exit}')
  [ -n "$BCAST" ] && ping -c 2 -t 3 "$BCAST" >/dev/null 2>&1
fi
arp -a -i "$IFACE" 2>/dev/null | grep -v incomplete | grep -v -E '\(2(2[4-9]|3[0-9])\.|255\)' \
  | sed -E 's/ at [0-9a-f:]+/ at (MAC masquée)/' | tee "$TMP/arp.txt"
NBAPP=$(wc -l < "$TMP/arp.txt" | tr -d ' ')
echo "Appareils visibles : $NBAPP (liste partielle : certains appareils ne répondent pas)"
[ "$NBAPP" -ge 25 ] && alerte "Beaucoup d'appareils sur le réseau ($NBAPP) : ils se partagent le temps d'antenne ; un appareil lent ou ancien ralentit tout le monde."

# -----------------------------------------------------------------------------
titre "RÉSUMÉ"
if [ -s "$ALERTES" ]; then
  echo "Ce qui ralentit probablement ton Wi-Fi :"
  cat "$ALERTES"
else
  echo "Aucun problème évident détecté pendant ce test."
fi
if [ -s "$OK" ]; then
  echo; echo "Ce qui va bien :"; cat "$OK"
fi
cat <<'EOF'

À vérifier aussi dans l'interface du routeur (souvent http://192.168.1.1 ou 192.168.1.254) :
  - Firmware à jour, et routeur redémarré récemment ?
  - Canal en « Auto » ou fixé sur un canal encombré ?
  - 5 GHz activé ? WPA2/WPA3 (pas WEP/WPA/TKIP, qui bride le débit) ?
  - Appareils inconnus dans la liste des clients connectés ?
Conseil : lance le test une fois près du routeur et une fois à l'endroit où ça rame,
puis compare les deux rapports.
EOF
echo
echo "Rapport enregistré : $OUT"
