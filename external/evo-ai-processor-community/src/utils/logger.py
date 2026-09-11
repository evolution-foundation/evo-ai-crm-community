"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: logger.py                                                             │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: July, 21, 2023                                                │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2023. All rights reserved.                        │
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

import logging
import sys
from src.config.settings import settings

# Configure logger for the application
def setup_logger(name):
    """
    Configure logger

    Returns:
        logging.Logger: Logger object
    """
    # Main logger
    logger = logging.getLogger(name)

    # If logger is already configured, return it
    if logger.handlers:
        return logger

    # Get log level from settings
    log_level_str = settings.LOG_LEVEL
    log_level = getattr(logging, log_level_str.upper(), logging.INFO)

    logger.setLevel(log_level)

    # Configure format
    formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s (%(filename)s:%(lineno)d)"
    )

    # Console handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    # Prevent logs from being propagated to the root logger
    logger.propagate = False

    return logger