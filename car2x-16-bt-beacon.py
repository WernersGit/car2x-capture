#!/usr/bin/env python3
# car2x-bt-beacon.py
# Bluetooth LE Beacon Scanner with full advertisement data extraction
# Outputs compact JSONL with: MAC, RSSI, Names, TX Power, Manufacturer, Service UUIDs

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from bleak import BleakScanner

async def scan_bluetooth(duration: float = 1.0):
    """Scan for BLE devices and return parsed advertisement data"""
    devices = await BleakScanner.discover(timeout=duration, return_adv=True)
    
    result = []
    for address, (device, adv_data) in devices.items():
        device_info = {
            "mac": address.replace(":", ""),  # compact MAC
            "rssi": adv_data.rssi
        }
        
        # Names (record both sources if present)
        if adv_data.local_name:
            device_info["name_adv"] = adv_data.local_name
        
        if device.name and device.name != "Unknown":
            device_info["name_dev"] = device.name
        
        # TX Power
        if adv_data.tx_power is not None:
            device_info["tx"] = adv_data.tx_power
        
        # Manufacturer Data
        if adv_data.manufacturer_data:
            mfg_id, mfg_data = next(iter(adv_data.manufacturer_data.items()))
            device_info["mfg"] = f"{mfg_id:04X}"
            
            if mfg_data and len(mfg_data) > 0:
                device_info["mfg_data"] = mfg_data.hex()
        
        # Service UUIDs
        if adv_data.service_uuids:
            device_info["svc"] = [
                uuid.split("-")[0][-4:] if len(uuid) > 8 else uuid 
                for uuid in adv_data.service_uuids
            ]
        
        # Service Data
        if adv_data.service_data:
            svc_data = {}
            for uuid, data in adv_data.service_data.items():
                short_uuid = uuid.split("-")[0][-4:] if len(uuid) > 8 else uuid
                svc_data[short_uuid] = data.hex()
            device_info["svc_data"] = svc_data
        
        result.append(device_info)
    
    return result

async def main():
    trip_path = os.getenv('CAR2X_DRIVE_PATH')
    scan_interval = float(os.getenv('CAR2X_BT_SCAN_INTERVAL', '2.0'))
    
    if trip_path:
        trip_dir = Path(trip_path)
        trip_dir.mkdir(parents=True, exist_ok=True)
        output_file = trip_dir / "bt_beacons.jsonl"
        
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] Writing to: {output_file}",
              file=sys.stderr)
        
        file_handle = open(output_file, 'a', buffering=1)
    else:
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] CAR2X_DRIVE_PATH not set, writing to stdout",
              file=sys.stderr)
        file_handle = sys.stdout
    
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] Starting BLE scanner (interval: {scan_interval}s)", 
          file=sys.stderr)
    
    try:
        while True:
            timestamp = int(time.time())
            
            try:
                devices = await scan_bluetooth(duration=1.0)
                
                output = {
                    "ts": timestamp,
                    "devs": devices
                }
                
                print(json.dumps(output, separators=(',', ':')), file=file_handle)
                file_handle.flush()
                
            except Exception as e:
                print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] ERROR: {e}", 
                      file=sys.stderr)
            
            await asyncio.sleep(scan_interval - 1.0)
    finally:
        if file_handle != sys.stdout:
            file_handle.close()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] Scanner stopped", 
              file=sys.stderr)