# Jellyfin DVD Ripper (TV & Movies)

A set of Bash scripts to automate ripping **TV show** and **movie** DVDs directly into your Jellyfin library on a Proxmox container.  
Supports **interactive** and **batch** modes for TV shows, automatic file naming for Jellyfin, and multi-disc handling.

---

## Features
- Works with **Proxmox containers** using `pct` commands
- **TV Mode**:
  - Interactive episode selection or batch ripping
  - Automatically detects episodes (20+ minutes duration)
  - Handles multi-disc seasons with correct episode numbering
- **Movie Mode**:
  - Automatically rips the main movie title
  - Creates Jellyfin-ready file naming
- Transfers media directly into the Jellyfin library folder
- Automatically sets permissions for Jellyfin access
- Ejects DVD after processing

---

## Requirements
- **Proxmox** with a container running Jellyfin
- DVD drive accessible to the Proxmox host (`/dev/sr0` by default)
- [`HandBrakeCLI`](https://handbrake.fr/downloads2.php) installed on the Proxmox host
- `pct` commands available (Proxmox LXC management)
- `eject` command available
- Bash 4+

---

## Installation
1. Download both scripts to your Proxmox host:
   - `rip_tv.sh` — TV show ripper
   - `rip_movie.sh` — Movie ripper
2. Make them executable:
   ```bash
   chmod +x rip_tv.sh rip_movie.sh
   ```
3. Adjust the configuration variables in each script if needed:
   - `CONTAINER_ID` – your Jellyfin container ID
   - `JELLYFIN_PATH` – path to TV or movie folder inside the container
   - `DVD_DEVICE` – path to your DVD drive
   - `MOUNT_POINT` – temporary DVD mount point

---

## Usage

### TV Shows
```bash
./rip_tv.sh "Series Name (Year)" "Season Number" [Starting Episode Number] [Number of Episodes]
```

**Examples:**
- Interactive mode from episode 1:
  ```bash
  ./rip_tv.sh "The Sopranos (1999)" "01"
  ```
- Interactive mode from episode 5:
  ```bash
  ./rip_tv.sh "The Sopranos (1999)" "01" 5
  ```
- Batch mode (episodes 1–3):
  ```bash
  ./rip_tv.sh "The Sopranos (1999)" "01" 1 3
  ```
- Batch mode (episodes 10–13):
  ```bash
  ./rip_tv.sh "Friends (1994)" "02" 10 4
  ```

---

### Movies
```bash
./rip_movie.sh "Movie Title (Year)"
```

**Examples:**
- Standard movie:
  ```bash
  ./rip_movie.sh "The Matrix (1999)"
  ```
- With special edition tag:
  ```bash
  ./rip_movie.sh "Blade Runner (1982) Director's Cut"
  ```

---

## Modes

**TV Interactive Mode**  
- Choose disc number (optional)  
- Select from:
  1. Auto-rip episodes (20+ minutes each)
  2. Manual selection
  3. Rip all titles  

**TV Batch Mode**  
- Automatically rips a set number of episodes from the DVD  
- Useful when episode order matches title order

**Movie Mode**  
- Detects and rips the main feature (longest title) automatically  
- Single `.mkv` output ready for Jellyfin

---

## Output
Episodes will be saved in:
```
<Jellyfin TV path>/<Series Name>/Season <Season Number>/
```
Example:
```
/mnt/storage/media/jellyfin/tv_shows/The Sopranos (1999)/Season 01/The Sopranos (1999) S01E01.mkv
```

Movies will be saved in:
```
<Jellyfin Movies path>/<Movie Title (Year)>.mkv
```
Example:
```
/mnt/storage/media/jellyfin/movies/The Matrix (1999).mkv
```

---

