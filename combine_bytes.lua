-- Define the function to combine bytes
function combine_bytes(tag, timestamp, record)
    -- Check if 'flow' field exists
    if record["flow"] ~= nil then
        -- Check if both 'bytes_toclient' and 'bytes_toserver' fields exist
        if record["flow"]["bytes_toclient"] ~= nil and record["flow"]["bytes_toserver"] ~= nil then
            -- Calculate total bytes
            local total_bytes = record["flow"]["bytes_toclient"] + record["flow"]["bytes_toserver"]
            -- Add total bytes to a new field
                record["flow"]["total_bytes"] = total_bytes
        end
    end
    -- Return the modified record
    return 1, timestamp, record
end
