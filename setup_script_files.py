import os
import shutil
import sys

source_folders = ['concat', '3d_playlist_local']
extensions = ('.mp4', '.wmv', '.m4v', '.mkv', '.avi', '.ts')
init_ps_files = ['run_batch_convert_streamTo3D.ps1', 'run_batch_fisheye_v360.ps1', 'run_batch_vr_hybrid.ps1']

# Always copy from this script's folder (not process cwd — double-click / Enter launch often differs).
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def configure_stdio():
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, 'reconfigure', None)
        if callable(reconfigure):
            try:
                reconfigure(encoding='utf-8', errors='replace')
            except Exception:
                pass


def log(message):
    try:
        print(message)
    except UnicodeEncodeError:
        encoding = getattr(sys.stdout, 'encoding', None) or 'utf-8'
        safe = message.encode(encoding, errors='replace').decode(encoding, errors='replace')
        print(safe)

def push_code_to_subdirectories(root_directory):
    """
    Pushes code to root and all subdirectories that contain media (mp4) files
    Args:
        root_directory (str): The path to the main directory to start scanning.
    """
    # print(f"Traversal list: {list(os.walk(root_directory))}")
    for dirpath, dirnames, filenames in os.walk(root_directory):
        # print(f"Scanning directory '{dirpath}'")
        if any(source_folder in dirpath for source_folder in source_folders):
            log(f"Ignoring folder '{', '.join(source_folders)}' "
                f"subdirectories at {dirpath}!")
            continue
        media_files_in_current_dir = []
        for filename in filenames:
            if filename.lower().endswith(extensions):
                media_files_in_current_dir.append(filename)
                break

        if media_files_in_current_dir:  # Only copy if media is found
            for init_ps_file in init_ps_files:
                src = os.path.join(_SCRIPT_DIR, init_ps_file)
                try:
                    if not os.path.isfile(src):
                        log(f"Error: Source file not found: {src}")
                        continue
                    shutil.copy2(src, dirpath)
                    log(f"{init_ps_file} copied to {dirpath}")
                except FileNotFoundError:
                    log(f"Error: Source file not found: {src}")
                except Exception as e:
                    log(f"An error occurred copying {init_ps_file} -> {dirpath}: {e}")
        else:
            log(f"No media found in directory '{dirpath}'. Skipping!")


def deploy_web_companion_hub(hub_dir):
    """Deploy batch launchers + 3d_playlist_local to the pCloud web-companion hub (no local media required)."""
    os.makedirs(hub_dir, exist_ok=True)
    dest_playlist = os.path.join(hub_dir, '3d_playlist_local')
    try:
        if os.path.isdir(dest_playlist):
            shutil.rmtree(dest_playlist)
        shutil.copytree(
            _SCRIPT_DIR,
            dest_playlist,
            ignore=shutil.ignore_patterns('ai', 'ign', '.git', 'standardized', 'avs', 'op_logs', 'transcode_logs', '*.log'),
        )
        log(f"3d_playlist_local copied to {dest_playlist}")
    except Exception as e:
        log(f"Error copying 3d_playlist_local -> {dest_playlist}: {e}")
    for init_ps_file in init_ps_files:
        src = os.path.join(_SCRIPT_DIR, init_ps_file)
        try:
            if not os.path.isfile(src):
                log(f"Error: Source file not found: {src}")
                continue
            shutil.copy2(src, hub_dir)
            log(f"{init_ps_file} copied to {hub_dir}")
        except Exception as e:
            log(f"An error occurred copying {init_ps_file} -> {hub_dir}: {e}")


def register_scripts_root():
    """Record the scripts root (parent of this 3d_playlist_local) so launchers deployed to media
    folders find it on any drive. Same pointer file as individual_transcode\\Resolve-AllScriptsRoot.ps1."""
    scripts_root = os.path.dirname(_SCRIPT_DIR)
    # LOCALAPPDATA, not APPDATA\\3d_playlist_local (that folder is the DLNA segment store / Skybox share).
    app_data = os.environ.get('LOCALAPPDATA')
    if not app_data:
        log('LOCALAPPDATA not set; scripts-root pointer not written (set ALL_SCRIPTS_ROOT instead).')
        return scripts_root
    pointer = os.path.join(app_data, '3d_playlist_local', 'all_scripts_root.txt')
    try:
        os.makedirs(os.path.dirname(pointer), exist_ok=True)
        with open(pointer, 'w', encoding='utf-8') as fh:
            fh.write(scripts_root)
        log(f"Scripts root registered: {scripts_root} -> {pointer}")
    except OSError as e:
        log(f"Could not write scripts-root pointer {pointer}: {e}")
    return scripts_root


def parse_args(argv):
    """setup_script_files.py [MEDIA_ROOT ...] [--hub PATH | --no-hub]
    No MEDIA_ROOT -> DEFAULT_MEDIA_ROOTS. Missing roots/drives are skipped."""
    roots, hub, i = [], DEFAULT_WEB_COMPANION_HUB, 0
    while i < len(argv):
        a = argv[i]
        if a == '--no-hub':
            hub = None
        elif a == '--hub' and i + 1 < len(argv):
            i += 1
            hub = argv[i]
        else:
            roots.append(a)
        i += 1
    return (roots or list(DEFAULT_MEDIA_ROOTS)), hub


DEFAULT_MEDIA_ROOTS = ['F:\\f1_media', 'E:\\e1_media', 'D:\\d1_media', 'P:\\p_cld_media', 'L:\\pcld_ios_media']
DEFAULT_WEB_COMPANION_HUB = r'P:\p_cld_media\web_compann_plst'


if __name__ == '__main__':
    configure_stdio()
    register_scripts_root()
    log(f"Copying batch launchers from: {_SCRIPT_DIR}")
    log(f"Files: {', '.join(init_ps_files)}")
    root_dirs, web_companion_hub = parse_args(sys.argv[1:])
    for root_dir in root_dirs:
        if not os.path.isdir(root_dir):
            log(f"Media root not found, skipping: {root_dir}")
            continue
        push_code_to_subdirectories(root_dir)
    hub_drive = os.path.splitdrive(web_companion_hub)[0] if web_companion_hub else ''
    if not web_companion_hub:
        log('Web companion hub skipped (--no-hub).')
    elif hub_drive and not os.path.isdir(hub_drive + os.sep):
        log(f"Web companion hub skipped (drive {hub_drive} not present): {web_companion_hub}")
    else:
        log(f"Deploying web companion hub: {web_companion_hub}")
        deploy_web_companion_hub(web_companion_hub)
    try:
        input('Done. Press Enter to close...')
    except EOFError:
        pass
