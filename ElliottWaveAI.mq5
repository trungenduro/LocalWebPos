//+------------------------------------------------------------------+
//|                                              ElliottWaveAI.mq5 |
//|                                      AI Elliott Wave Trading EA  |
//+------------------------------------------------------------------+
#property copyright "AI Auto Trader"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Input Parameters
input string   AIServerURL       = "http://127.0.0.1:5000/analyze"; // AI Server URL (Node.js/Python)
input int      ZigZagDepth       = 12;                              // ZigZag Depth
input int      ZigZagDeviation   = 5;                               // ZigZag Deviation
input int      ZigZagBackstep    = 3;                               // ZigZag Backstep
input double   RiskLots          = 0.05;                            // Trade Volume (Lots)
input ulong    MagicNumber       = 777777;                          // EA Magic Number

//--- Global Variables
int            zigzag_handle;
CTrade         trade;
datetime       last_bar_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize Trade object
    trade.SetExpertMagicNumber(MagicNumber);
    
    // Load the built-in ZigZag indicator
    zigzag_handle = iCustom(_Symbol, PERIOD_CURRENT, "Examples\\ZigZag", ZigZagDepth, ZigZagDeviation, ZigZagBackstep);
    
    if(zigzag_handle == INVALID_HANDLE)
    {
        Print("Error loading ZigZag indicator!");
        return(INIT_FAILED);
    }
    
    Print("Elliott Wave AI EA Initialized. Server: ", AIServerURL);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(zigzag_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Only run analysis once per new bar to save API calls
    datetime current_bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(current_bar_time != last_bar_time)
    {
        last_bar_time = current_bar_time;
        AnalyzeAndTrade();
    }
}

//+------------------------------------------------------------------+
//| Main Logic: Get Data -> Send to AI -> Trade                      |
//+------------------------------------------------------------------+
void AnalyzeAndTrade()
{
    // 1. Get recent ZigZag Pivot Points
    string json_payload = BuildJSONPayload();
    if(json_payload == "") return;
    
    Print("Sending Data to AI: ", json_payload);
    
    // 2. Send to AI Backend via HTTP POST
    char post_data[];
    char result_data[];
    string result_headers;
    
    StringToCharArray(json_payload, post_data, 0, WHOLE_ARRAY, CP_UTF8);
    string headers = "Content-Type: application/json\r\n";
    
    ResetLastError();
    int res = WebRequest("POST", AIServerURL, headers, 5000, post_data, result_data, result_headers);
    
    // 3. Process AI Response
    if(res == 200)
    {
        string ai_response = CharArrayToString(result_data);
        Print("AI Response: ", ai_response);
        ProcessAIResponse(ai_response);
    }
    else
    {
        Print("Failed to connect to AI Server. Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Extract ZigZag points and format as JSON                         |
//+------------------------------------------------------------------+
string BuildJSONPayload()
{
    double zigzag[];
    ArraySetAsSeries(zigzag, true); // Index 0 is the current candle
    
    // Copy the last 300 bars of ZigZag data
    if(CopyBuffer(zigzag_handle, 0, 0, 300, zigzag) <= 0) return "";
    
    string json = "{ \"symbol\": \"" + _Symbol + "\", \"timeframe\": \"" + EnumToString(Period()) + "\", \"swings\": [";
    int found = 0;
    
    // Search backwards to find the last 6 swing points
    for(int i = 0; i < 300 && found < 6; i++)
    {
        if(zigzag[i] > 0.0 && zigzag[i] != EMPTY_VALUE)
        {
            if(found > 0) json += ",";
            json += DoubleToString(zigzag[i], _Digits);
            found++;
        }
    }
    json += "]";
    
    // Take Screenshot and get Base64
    string base64_image = GetChartScreenshotBase64();
    if(base64_image != "")
    {
        json += ", \"image_base64\": \"" + base64_image + "\"";
    }
    
    json += " }";
    
    // If we don't have enough swings to analyze a wave, return empty
    if(found < 4) return "";
    
    return json;
}

//+------------------------------------------------------------------+
//| Take Screenshot and encode to Base64                             |
//+------------------------------------------------------------------+
string GetChartScreenshotBase64()
{
    string filename = "ai_chart_screenshot.png";
    
    // 1. Take a screenshot (800x600 resolution)
    if(!ChartScreenShot(0, filename, 800, 600, ALIGN_RIGHT))
    {
        Print("Failed to take screenshot. Error: ", GetLastError());
        return "";
    }
    
    // 2. Open the image file as binary
    int file_handle = FileOpen(filename, FILE_READ|FILE_BIN);
    if(file_handle == INVALID_HANDLE)
    {
        Print("Failed to open screenshot file. Error: ", GetLastError());
        return "";
    }
    
    // 3. Read file into a uchar array
    int file_size = (int)FileSize(file_handle);
    uchar image_data[];
    ArrayResize(image_data, file_size);
    FileReadArray(file_handle, image_data, 0, file_size);
    FileClose(file_handle);
    
    // 4. Encode to Base64
    uchar base64_data[];
    uchar key[]; // Empty key for Base64 encoding
    int encoded_size = CryptEncode(CRYPT_BASE64, image_data, key, base64_data);
    
    if(encoded_size > 0)
    {
        // Convert uchar array to string
        string base64_string = CharArrayToString(base64_data);
        // Remove newlines from base64 string to avoid JSON errors
        StringReplace(base64_string, "\r\n", "");
        StringReplace(base64_string, "\n", "");
        return base64_string;
    }
    
    return "";
}

//+------------------------------------------------------------------+
//| Parse AI JSON Response and Place Orders                          |
//+------------------------------------------------------------------+
void ProcessAIResponse(string json)
{
    // Basic String parsing to extract values from AI JSON
    // Expected JSON: {"signal": "BUY_LIMIT", "wait_price_entry": 2325.00, "take_profit": 2380.00, "stop_loss": 2295.00, "analysis": "..."}
    
    string signal = ParseJSONString(json, "signal");
    string analysis = ParseJSONString(json, "analysis");
    
    if(signal == "WAIT" || signal == "") 
    {
        Print("AI said WAIT. No trades placed.");
        return;
    }
    
    double entry_price = StringToDouble(ParseJSONString(json, "wait_price_entry"));
    double tp = StringToDouble(ParseJSONString(json, "take_profit"));
    double sl = StringToDouble(ParseJSONString(json, "stop_loss"));
    
    if(entry_price <= 0 || tp <= 0 || sl <= 0)
    {
        Print("Invalid price data from AI.");
        return;
    }
    
    // Cancel existing pending orders for this EA to avoid duplicates
    CancelPendingOrders();
    
    string notification_msg = "";
    
    // Place new pending orders based on AI prediction
    if(signal == "BUY_LIMIT")
    {
        Print("AI Elliott Wave Detected! Placing BUY LIMIT at ", entry_price);
        trade.BuyLimit(RiskLots, entry_price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "AI Wave 3 Buy");
        notification_msg = "📈 AI BUY Signal on " + _Symbol + "\nEntry: " + DoubleToString(entry_price, _Digits) + "\nTP: " + DoubleToString(tp, _Digits) + "\nSL: " + DoubleToString(sl, _Digits) + "\nAnalysis: " + analysis;
    }
    else if(signal == "SELL_LIMIT")
    {
        Print("AI Elliott Wave Detected! Placing SELL LIMIT at ", entry_price);
        trade.SellLimit(RiskLots, entry_price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "AI Wave 3 Sell");
        notification_msg = "📉 AI SELL Signal on " + _Symbol + "\nEntry: " + DoubleToString(entry_price, _Digits) + "\nTP: " + DoubleToString(tp, _Digits) + "\nSL: " + DoubleToString(sl, _Digits) + "\nAnalysis: " + analysis;
    }
    
    // Send Notification to MT5 Mobile App
    if(notification_msg != "")
    {
        SendNotification(notification_msg);
    }
}

//+------------------------------------------------------------------+
//| Simple JSON key extractor (Helper Function)                      |
//+------------------------------------------------------------------+
string ParseJSONString(string json, string key)
{
    int key_pos = StringFind(json, "\"" + key + "\"");
    if(key_pos < 0) return "";
    
    int colon_pos = StringFind(json, ":", key_pos);
    int comma_pos = StringFind(json, ",", colon_pos);
    int brace_pos = StringFind(json, "}", colon_pos);
    
    int end_pos = comma_pos;
    if(comma_pos < 0 || (brace_pos > 0 && brace_pos < comma_pos)) end_pos = brace_pos;
    
    string val = StringSubstr(json, colon_pos + 1, end_pos - colon_pos - 1);
    StringReplace(val, "\"", "");
    StringTrimLeft(val); 
    StringTrimRight(val);
    
    return val;
}

//+------------------------------------------------------------------+
//| Cancel all pending orders for this EA                            |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol)
        {
            trade.OrderDelete(ticket);
        }
    }
}
