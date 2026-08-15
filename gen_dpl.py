import sys
import os
import time
import shutil
import math
from pathlib import Path
from pprint import pprint


# fixes python script cwd error on double click!
# Get the directory where the script is located
script_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
# Change the current working directory to the script's directory
os.chdir(script_dir)
print("Current working directory changed to:", os.getcwd()) # For verification


def move_media_files_recursive(source_dir, dest_dir):
    """
    Moves media (avs) files from a source folder to a destination folder.

    Args:
        source_dir (str): The path to the source directory.
        dest_dir (str): The path to the destination directory.
    """

    source_path = Path(source_dir)
    dest_path = Path(dest_dir)

    # Create the destination directory if it doesn't exist
    dest_path.mkdir(parents=True, exist_ok=True)

    # Use rglob to find all .avs files recursively
    for file_path in source_path.rglob("*.avs"):
        # Define the destination path for the file
        destination_file_path = dest_path / file_path.name
        
        try:
            # Move the file
            shutil.move(file_path, destination_file_path)
            print(f"Moved: {file_path} -> {destination_file_path}")
        except shutil.Error as e:
            # Handle potential errors, e.g., file already exists at destination
            print(f"Error moving {file_path}: {e}")
        except Exception as e:
            # Handle other unexpected errors
            print(f"An unexpected error occurred with file {file_path}: {e}")

# Define your source and destination folder paths
source_directory = 'C:\\ProgramData\\StreamTo3D'
destination_directory = '.\\avs'

move_media_files_recursive(source_directory, destination_directory)


pref_substr = 'rand_combo.m'
pref_substr_max_cnt = 30
pref_substr_ctr = 0
oldest_pref_substr_ts = math.inf
oldest_pref_substr_idx = -1
sort_tuples = []

"""
Prioritizes newer rand_combo files till they hit max. count = pref_substr_max_cnt.
Within priority and non-priority groups, sort by modification time ascending (oldest first).
Non-rand_combo files + older rand_combo surplus use the same ascending timestamp order.
"""
def sort_key(file_index, filename, folder_path):
    global pref_substr_ctr
    global oldest_pref_substr_ts
    global oldest_pref_substr_idx
    global sort_tuples
    # Priority check: False (rand_combo) comes before True
    is_not_priority = pref_substr not in filename
    # Ascending mtime (oldest first within each priority group)
    file_ts = os.path.getmtime(os.path.join(folder_path, filename))
    if not is_not_priority:
        if file_ts < oldest_pref_substr_ts:
            oldest_pref_substr_idx = file_index
            oldest_pref_substr_ts = file_ts
        pref_substr_ctr += 1
        if pref_substr_ctr > pref_substr_max_cnt:
            sort_tuples[oldest_pref_substr_idx] = (True, oldest_pref_substr_ts)
            pref_substr_ctr -= 1
    final_priority = (is_not_priority, file_ts)
    sort_tuples.append(final_priority)
    return final_priority

def create_playlists(folder_path, m3u_output_filename=".\\playlist.m3u", dpl_output_filename=".\\playlist_potplayer.dpl"):
    """
    Creates both M3U and PotPlayer DPL playlist files for all media files in a given folder.
    Order: up to pref_substr_max_cnt newest rand_combo first (mtime asc within), then the rest (mtime asc).
    """
    global pref_substr_ctr
    global oldest_pref_substr_ts
    global oldest_pref_substr_idx
    global sort_tuples
    media_files = [f for f in os.listdir(folder_path) if f.endswith(('.avs'))]
    if media_files == []:
        print(f"No avs files found in {folder_path}. Exiting!")
        return
    pref_substr_ctr = 0
    oldest_pref_substr_ts = math.inf
    oldest_pref_substr_idx = -1
    sort_tuples = []
    for fidx, fn in enumerate(media_files):
        sort_key(fidx, fn, folder_path)
    media_files_sorted_zipped = sorted(zip(media_files, sort_tuples)
                         , key=lambda fln_sort_tpl: (fln_sort_tpl[1][0], fln_sort_tpl[1][1]), reverse=False)
    media_files, _ = zip(*media_files_sorted_zipped)
    pprint(media_files)
    # Write M3U (kept for orchestrator/other tooling)
    with open(m3u_output_filename, 'w', encoding='utf-8') as f:
        f.write("#EXTM3U\n")
        for media_file in media_files:
            # Use absolute path for robustness
            full_path = os.path.join(folder_path, media_file)
            # PotPlayer handles Windows paths correctly
            f.write(f"{full_path}\n")
    print(f"Created M3U playlist file: {os.path.abspath(m3u_output_filename)}")

    # Write PotPlayer DPL separately for direct PotPlayer loading
    with open(dpl_output_filename, 'w', encoding='utf-8') as f:
        f.write("DAUMPLAYLIST\n")
        f.write("playname=\n")
        f.write("topindex=0\n")
        f.write("saveplaypos=1\n")
        for idx, media_file in enumerate(media_files, start=1):
            full_path = os.path.join(folder_path, media_file)
            f.write(f"{idx}*file*{full_path}\n")
            f.write(f"{idx}*title*{media_file}\n")
    print(f"Created PotPlayer DPL playlist file: {os.path.abspath(dpl_output_filename)}")

# create_playlists("F:\\all_scripts\\global_rand_3d_playlist\\avs")
create_playlists(".\\avs")
