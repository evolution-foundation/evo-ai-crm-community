import uuid
from google.adk.tools import ToolContext
from google.genai import types
import httpx
from google.adk.tools import FunctionTool
import logging

logger = logging.getLogger(__name__)


def create_text_to_speech_tool(
    eleven_labs_token: str,
    voice_id: str,
    model_id: str,
    stability: float,
    similarity_boost: float,
    style: float,
    use_speaker_boost: bool,
) -> FunctionTool:
    """Create the text_to_speech tool for LoopAgent.

    Args:
        eleven_labs_token: The token for the ElevenLabs API
        voice_id: The voice ID to use for the speech
        model_id: The model ID to use for the speech
        stability: Voice stability setting
        similarity_boost: Voice similarity boost setting
        style: Voice style setting
        use_speaker_boost: Whether to use speaker boost
    """

    async def text_to_speech(
        text: str,
        tool_context: "ToolContext",
    ):
        """Generates speech from text with ElevenLabs and stores it in artifacts."""
        try:
            # Validate text length (ElevenLabs has limits)
            if not text or not text.strip():
                return {
                    "status": "failed",
                    "error": "Text cannot be empty",
                }

            # ElevenLabs free tier typically has a 5000 character limit
            if len(text) > 5000:
                return {
                    "status": "failed",
                    "error": f"Text too long ({len(text)} characters). Maximum allowed is 5000 characters.",
                }

            logger.info(f"Generating speech for text: {len(text)} characters")

            # Use async client with timeout configuration
            timeout = httpx.Timeout(60.0)  # 60 seconds timeout
            async with httpx.AsyncClient(timeout=timeout) as client:
                logger.info(
                    f"Making request to ElevenLabs API with voice_id: {voice_id}, model_id: {model_id}"
                )

                response = await client.post(
                    f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
                    headers={"xi-api-key": eleven_labs_token},
                    json={
                        "text": text,
                        "model_id": model_id,
                        "voice_settings": {
                            "stability": stability,
                            "similarity_boost": similarity_boost,
                            "style": style,
                            "use_speaker_boost": use_speaker_boost,
                        },
                    },
                )

                logger.info(f"ElevenLabs API response status: {response.status_code}")

                if not response.is_success:
                    error_detail = ""
                    try:
                        error_detail = response.text
                    except:
                        error_detail = "Unknown error"

                    return {
                        "status": "failed",
                        "error": f"ElevenLabs API error: {response.status_code} - {error_detail}",
                    }

                # Get audio buffer from response
                audio_bytes = response.content
                logger.info(f"Received audio response: {len(audio_bytes)} bytes")

            # Generate unique filename
            filename = f"speech_{uuid.uuid4().hex[:8]}.mp3"

            # Create a simple byte blob without complex type annotations
            # This avoids LiteLLM compatibility issues
            audio_blob = types.Blob(mime_type="audio/mpeg", data=audio_bytes)

            # Create Part with inline_data instead of using from_bytes
            audio_part = types.Part(inline_data=audio_blob)

            # Save to artifacts using the tool context
            version = await tool_context.save_artifact(filename, audio_part)

            # Initialize result with basic information
            result = {
                "status": "success",
                "detail": "Speech generated successfully and stored in artifacts.",
                "filename": filename,
                "version": str(version),  # Ensure version is string
            }

            # Use load_artifact to get the presigned URL
            # The MinIO artifact service automatically detects audio files and returns presigned URLs
            try:
                logger.info(f"Loading artifact {filename} to get presigned URL")
                loaded_artifact = await tool_context.load_artifact(filename, version)

                if loaded_artifact and loaded_artifact.text:
                    # The MinIO service returns presigned URLs for binary files in the text field
                    # Format: "Artifact URL: https://..."
                    if loaded_artifact.text.startswith("Artifact URL: "):
                        audio_url = loaded_artifact.text.replace("Artifact URL: ", "")
                        result["audio_url"] = audio_url
                        logger.info(f"Successfully generated audio URL: {audio_url}")
                    else:
                        logger.warning(
                            f"Unexpected artifact text format: {loaded_artifact.text}"
                        )
                        result["url_hint"] = loaded_artifact.text
                else:
                    logger.warning("Could not load artifact to generate URL")
                    result["url_hint"] = (
                        f"Audio file saved as {filename} version {version}. Use load_artifact to access."
                    )

            except Exception as e:
                # Don't fail the entire operation if URL generation fails
                logger.warning(f"Failed to generate audio URL for {filename}: {e}")
                result["url_error"] = str(e)
                result["url_hint"] = (
                    f"Audio file saved as {filename} version {version}. Contact your administrator to configure proper URL generation."
                )

            logger.info(
                f"Successfully generated speech: {filename} (version {version})"
            )
            return result

        except httpx.TimeoutException:
            logger.error("ElevenLabs API request timed out")
            return {
                "status": "failed",
                "error": "ElevenLabs API request timed out after 60 seconds. This might be due to: 1) Network connectivity issues, 2) ElevenLabs server overload, 3) Text too complex for processing. Try again with shorter text or check your internet connection.",
            }
        except httpx.RequestError as e:
            logger.error(f"ElevenLabs API request error: {str(e)}")
            return {
                "status": "failed",
                "error": f"Network error connecting to ElevenLabs API: {str(e)}. Please check your internet connection and try again.",
            }
        except Exception as e:
            logger.error(f"Error in text_to_speech tool: {str(e)}")
            return {
                "status": "failed",
                "error": f"Text-to-speech error: {str(e)}",
            }

    # Set the function name and docstring for better tool description
    text_to_speech.__name__ = "text_to_speech"
    text_to_speech.__doc__ = f"""Generate speech from text with ElevenLabs.
    
    Args:
        text: The text to generate speech from
        tool_context: The tool context containing session information
    
    Returns:
        Dictionary with status, detail message, filename, version, and audio_url (if available)
    """

    return text_to_speech
