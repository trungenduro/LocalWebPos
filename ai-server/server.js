require('dotenv').config();
const express = require('express');
const { GoogleGenerativeAI } = require('@google/generative-ai');

const app = express();
app.use(express.text({ type: '*/*', limit: '15mb' }));

const PORT = process.env.PORT || 5000;

// Initialize Google Gemini AI
// Make sure you have GEMINI_API_KEY in your .env file
const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY);

app.post('/analyze', async (req, res) => {
    try {
        const rawBody = (typeof req.body === 'string' ? req.body : '').replace(/\u0000/g, '').trim();
        const data = rawBody ? JSON.parse(rawBody) : {};
        console.log("---------------------------------------------------");
        console.log(`[${new Date().toISOString()}] Received data from MT5:`, JSON.stringify(data));

        // Basic validation: We need at least 4 swings to analyze an Elliott Wave
        if (!data.swings || data.swings.length < 4) {
            console.log("Not enough swings for analysis. Returning WAIT.");
            return res.json({ signal: "WAIT" });
        }

        // Prepare the prompt for Google Gemini
        const promptText = `
You are an expert algorithmic trader specializing in Elliott Wave Theory and Technical Analysis.
I am providing you with a screenshot of the current trading chart and some recent swing data.

Data:
Symbol: ${data.symbol}
Timeframe: ${data.timeframe}
Recent Swings (from oldest to newest): ${data.swings ? data.swings.join(', ') : 'N/A'}

Your tasks:
1. Visually analyze the provided chart screenshot. Look at the price action, indicators, and overall trend.
2. Combine your visual analysis with the numerical swing data provided to determine if we are currently forming a Wave 2 (anticipating Wave 3) or a Wave B (anticipating Wave C).
3. If a high-probability setup is imminent, calculate the ideal Entry Price.
4. Calculate the Take Profit (TP) and Stop Loss (SL).

If there is no clear setup, return "signal": "WAIT".
You must respond STRICTLY in valid JSON format, with no markdown code blocks or extra text.

Example JSON output format:
{
  "signal": "BUY_LIMIT",
  "wait_price_entry": 2325.00,
  "take_profit": 2380.90,
  "stop_loss": 2295.00,
  "analysis": "Based on the chart image, price is bouncing off the 200 EMA and RSI is oversold. Numerical data confirms Wave 2 completion at 0.618 Fib. Anticipating bullish Wave 3."
}
`;

        // Prepare the content array (Text + Image)
        const requestContent = [promptText];

        // If MT5 sent an image (Base64), add it to the request
        if (data.image_base64) {
            console.log("🖼️ Chart image received from MT5. Attaching to Gemini prompt...");
            requestContent.push({
                inlineData: {
                    data: data.image_base64,
                    mimeType: "image/png"
                }
            });
        }

        // Use the Gemini 2.5 Flash model (supports multimodal vision)
        const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash" });
        
        console.log("Sending prompt and image to Gemini AI...");
        const result = await model.generateContent(requestContent);
        const responseText = result.response.text();
        
        console.log("Gemini Raw Response:", responseText);

        // Clean up the response in case Gemini wraps it in markdown (```json ... ```)
        let cleanJson = responseText.replace(/```json/gi, '').replace(/```/g, '').trim();
        
        // Parse the JSON and send it back to MT5
        const aiResponse = JSON.parse(cleanJson);
        console.log("Parsed Response sent to MT5:", aiResponse);
        
        res.json(aiResponse);

    } catch (error) {
        console.error("Error analyzing data with Gemini:", error);
        // Fallback response so the EA doesn't crash
        res.status(500).json({ signal: "WAIT", error: "AI Server Error" });
    }
});

app.listen(PORT, () => {
    console.log(`===================================================`);
    console.log(`🚀 AI Server running on http://127.0.0.1:${PORT}`);
    console.log(`🧠 Using Google Gemini API`);
    console.log(`⏳ Waiting for MT5 EA data on /analyze endpoint...`);
    console.log(`===================================================`);
});
