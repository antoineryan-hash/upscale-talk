#!/usr/bin/env python3
"""Print Google Calendar attendee names for a recorded meeting."""

import argparse
import json
import os
import re
import subprocess
import sys
import warnings
import wave
from datetime import datetime, timedelta

with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
    except ImportError:
        Request = None
        Credentials = None
        InstalledAppFlow = None
        build = None


SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]
CLIENT_SERVICE = "claude-gchat-reader-oauth-client"
TOKEN_SERVICE = "claude-gcal-roster-oauth-token"


def _keychain_read(service):
    user = os.environ.get("USER")
    if not user:
        return None
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-a",
            user,
            "-s",
            service,
            "-w",
        ],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout[:-1] if result.stdout.endswith(b"\n") else result.stdout
    if (
        re.fullmatch(rb"[0-9a-fA-F]+", value)
        and len(value) % 2 == 0
        and len(value) > 200
    ):
        try:
            return bytes.fromhex(value.decode("ascii"))
        except ValueError:
            pass
    return value


def _keychain_write(service, value):
    user = os.environ.get("USER")
    if not user:
        raise RuntimeError("USER is not set")
    subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-a",
            user,
            "-s",
            service,
            "-w",
            value,
        ],
        capture_output=True,
        check=True,
    )


def authenticate():
    """Return usable Calendar credentials, refreshing and storing as needed."""
    if not all((Request, Credentials, InstalledAppFlow, build)):
        raise RuntimeError("Google client libraries are unavailable")

    credentials = None
    token_blob = _keychain_read(TOKEN_SERVICE)
    if token_blob:
        try:
            token_data = json.loads(token_blob.decode("utf-8"))
            granted_scopes = set(token_data.get("scopes") or [])
            if set(SCOPES).issubset(granted_scopes):
                credentials = Credentials.from_authorized_user_info(
                    token_data, SCOPES
                )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            credentials = None

    if credentials and credentials.valid:
        return credentials

    if credentials and credentials.expired and credentials.refresh_token:
        try:
            credentials.refresh(Request())
            _keychain_write(TOKEN_SERVICE, credentials.to_json())
            return credentials
        except Exception as exc:
            raise RuntimeError("OAuth token refresh failed") from exc

    client_blob = _keychain_read(CLIENT_SERVICE)
    if not client_blob:
        raise RuntimeError(
            f"OAuth client is missing from Keychain service {CLIENT_SERVICE}"
        )
    if not sys.stdin.isatty():
        raise RuntimeError("OAuth consent is required but no interactive terminal is available")

    try:
        client_config = json.loads(client_blob.decode("utf-8"))
        flow = InstalledAppFlow.from_client_config(client_config, SCOPES)
        credentials = flow.run_local_server(port=8091)
        _keychain_write(TOKEN_SERVICE, credentials.to_json())
        return credentials
    except Exception as exc:
        raise RuntimeError("OAuth consent failed") from exc


def parse_meeting_start(meeting_dir):
    """Parse a meeting folder's local timestamp into an aware datetime."""
    basename = os.path.basename(os.path.normpath(meeting_dir))
    parsed = datetime.strptime(basename, "%Y-%m-%d_%H-%M-%S")
    return parsed.astimezone()


def _wav_duration(path):
    """Return a robust WAV duration, mirroring meeting_transcribe.wav_duration."""
    try:
        with wave.open(path, "rb") as audio:
            nframes = audio.getnframes()
            frame_rate = audio.getframerate()
            channels = audio.getnchannels()
            sample_width = audio.getsampwidth() or 2
        denominator = frame_rate * channels * sample_width
        if not denominator:
            return None
        data_bytes = max(0, os.path.getsize(path) - 44)
        data_duration = data_bytes / denominator
        header_duration = nframes / frame_rate
        if (nframes in (0, 0x3FFFFFFF, 0xFFFFFFFF)
                or header_duration > data_duration * 1.05):
            return data_duration
        return header_duration
    except (OSError, EOFError, wave.Error):
        return None


def audio_duration_seconds(meeting_dir):
    """Return the preferred audio duration, or one hour when audio is absent."""
    for filename in ("me.wav", "them.wav"):
        path = os.path.join(meeting_dir, filename)
        if os.path.isfile(path):
            return _wav_duration(path)
    return 60 * 60


def _event_datetime(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo is not None else parsed.astimezone()


def _user_declined(event):
    return any(
        attendee.get("self") and attendee.get("responseStatus") == "declined"
        for attendee in event.get("attendees", [])
    )


def select_best_event(events, recording_start, recording_end):
    """Return the eligible event with the greatest recording overlap."""
    best_event = None
    best_overlap = 0.0
    for event in events:
        start_value = event.get("start", {}).get("dateTime")
        end_value = event.get("end", {}).get("dateTime")
        if not start_value or not end_value or _user_declined(event):
            continue
        try:
            event_start = _event_datetime(start_value)
            event_end = _event_datetime(end_value)
        except (TypeError, ValueError):
            continue
        overlap = (
            min(recording_end, event_end) - max(recording_start, event_start)
        ).total_seconds()
        if overlap > best_overlap:
            best_event = event
            best_overlap = overlap
    return best_event


def _entry_name(entry):
    display_name = (entry.get("displayName") or "").strip()
    if display_name:
        return display_name
    local_part = (entry.get("email") or "").split("@", 1)[0]
    words = re.sub(r"[._-]+", " ", local_part).strip()
    return words.title()


def extract_names(event, exclude_self=False):
    """Extract unique human attendee names, appending the organiser if absent."""
    names = []
    seen_names = set()
    seen_emails = set()

    def add_entry(entry):
        if entry.get("resource") or (exclude_self and entry.get("self")):
            return
        email = (entry.get("email") or "").strip().casefold()
        name = _entry_name(entry)
        name_key = name.casefold()
        if not name or (email and email in seen_emails) or name_key in seen_names:
            return
        names.append(name)
        seen_names.add(name_key)
        if email:
            seen_emails.add(email)

    for attendee in event.get("attendees", []):
        add_entry(attendee)
    organiser = event.get("organizer")
    if isinstance(organiser, dict):
        add_entry(organiser)
    return names


def fetch_events(credentials, time_min, time_max):
    service = build(
        "calendar", "v3", credentials=credentials, cache_discovery=False
    )
    result = (
        service.events()
        .list(
            calendarId="primary",
            timeMin=time_min.isoformat(),
            timeMax=time_max.isoformat(),
            singleEvents=True,
            orderBy="startTime",
        )
        .execute()
    )
    return result.get("items", [])


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Print attendee names for the calendar event matching a meeting."
    )
    parser.add_argument("meeting_dir")
    parser.add_argument("--slack-min", type=float, default=20)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--exclude-self", action="store_true")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    meeting_dir = os.path.abspath(os.path.expanduser(args.meeting_dir))
    try:
        recording_start = parse_meeting_start(meeting_dir)
    except (TypeError, ValueError):
        return 0

    try:
        duration = audio_duration_seconds(meeting_dir)
        recording_end = recording_start + timedelta(seconds=duration)
        slack = timedelta(minutes=args.slack_min)
        credentials = authenticate()
        events = fetch_events(
            credentials,
            recording_start - slack,
            recording_end + slack,
        )
        event = select_best_event(events, recording_start, recording_end)
        if event is None:
            raise RuntimeError("no overlapping calendar event")
        names = extract_names(event, exclude_self=args.exclude_self)
        if not names:
            raise RuntimeError("matching calendar event has no named attendees")
    except Exception as exc:
        reason = str(exc).replace("\n", " ").strip() or exc.__class__.__name__
        print(f"calendar roster unavailable: {reason}", file=sys.stderr)
        return 0

    if args.json:
        payload = {
            "event": event.get("summary", ""),
            "start": event.get("start", {}).get("dateTime", ""),
            "names": names,
        }
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(", ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
