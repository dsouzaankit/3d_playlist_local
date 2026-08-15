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

if __name__ == '__main__':
    configure_stdio()
    log(f"Copying batch launchers from: {_SCRIPT_DIR}")
    log(f"Files: {', '.join(init_ps_files)}")
    root_dirs = ['F:\\f1_media', 'E:\\e1_media', 'D:\\d1_media', 'P:\\p_cld_media', 'L:\\pcld_ios_media']
    for root_dir in root_dirs:
        # Replace 'your_root_directory_path' with the actual path you want to scan
        push_code_to_subdirectories(root_dir)
    try:
        input('Done. Press Enter to close...')
    except EOFError:
        pass
