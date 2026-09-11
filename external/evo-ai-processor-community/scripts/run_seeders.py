"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: run_seeders.py                                                        │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 13, 2025                                                  │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
│                                                                              │
│ You may not use this file except in compliance with the License.             │
│ You may obtain a copy of the License at                                      │
│                                                                              │
│    http://www.apache.org/licenses/LICENSE-2.0                                │
│                                                                              │
│ Unless required by applicable law or agreed to in writing, software          │
│ distributed under the License is distributed on an "AS IS" BASIS,            │
│ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     │
│ See the License for the specific language governing permissions and          │
│ limitations under the License.                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│ @important                                                                   │
│ For any future changes to the code in this file, it is recommended to        │
│ include, together with the modification, the information of the developer    │
│ who changed it and the date of modification.                                 │
└──────────────────────────────────────────────────────────────────────────────┘
"""

"""
Main script to run all seeders in sequence.
Checks dependencies between seeders and runs them in the correct order.
"""

import os
import sys
import logging
import argparse
from dotenv import load_dotenv

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Import seeders
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def setup_environment():
    """Configure the environment for seeders"""
    load_dotenv()

    # Check if essential environment variables are defined
    required_vars = ["POSTGRES_CONNECTION_STRING"]
    missing_vars = [var for var in required_vars if not os.getenv(var)]

    if missing_vars:
        logger.error(
            f"Required environment variables not defined: {', '.join(missing_vars)}"
        )
        return False

    return True


def run_seeders(seeders):
    """
    Run the specified seeders

    Args:
        seeders (list): List of seeders to run

    Returns:
        bool: True if all seeders were executed successfully, False otherwise
    """
    all_seeders = {
    }

    # Define the correct execution order (dependencies)
    seeder_order = []

    # If no seeder is specified, run all
    if not seeders:
        seeders = seeder_order
    else:
        # Check if all specified seeders exist
        invalid_seeders = [s for s in seeders if s not in all_seeders]
        if invalid_seeders:
            logger.error(f"Invalid seeders: {', '.join(invalid_seeders)}")
            logger.info(f"Available seeders: {', '.join(all_seeders.keys())}")
            return False

        # Ensure seeders are executed in the correct order
        seeders = [s for s in seeder_order if s in seeders]

    # Run seeders
    success = True
    for seeder_name in seeders:
        logger.info(f"Running seeder: {seeder_name}")

        try:
            seeder_func = all_seeders[seeder_name]
            if not seeder_func():
                logger.error(f"Failed to run seeder: {seeder_name}")
                success = False
        except Exception as e:
            logger.error(f"Error running seeder {seeder_name}: {str(e)}")
            success = False

    return success


def main():
    """Main function"""
    parser = argparse.ArgumentParser(description="Run seeders to populate the database")
    parser.add_argument(
        "--seeders",
        nargs="+",
        help="Seeders to run (optional, runs all if omitted)"
    )
    args = parser.parse_args()

    # Configure environment
    if not setup_environment():
        sys.exit(1)

    # Run seeders
    success = run_seeders(args.seeders)

    # Output
    if success:
        logger.info("All seeders were executed successfully")
        sys.exit(0)
    else:
        logger.error("There were errors running the seeders")
        sys.exit(1)


if __name__ == "__main__":
    main()
