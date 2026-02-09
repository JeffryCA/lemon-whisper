import logging
import os
import sys


def setup_logging(log_filename: str, temp_dir: str) -> str:
    """Set up logging to file and console.

    Args:
        log_filename (str): The name for the log file.
        temp_dir (str): The directory where the log file will be stored.

    Returns:
        str: The full path to the log file.
    """
    log_file = os.path.join(temp_dir, log_filename)
    os.makedirs(temp_dir, exist_ok=True)

    # Remove existing log file if it exists
    if os.path.exists(log_file):
        os.remove(log_file)

    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[logging.FileHandler(log_file), logging.StreamHandler(sys.stdout)],
    )

    return log_file
