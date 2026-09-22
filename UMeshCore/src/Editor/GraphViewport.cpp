#include "umeshcore/Editor/GraphViewport.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

// ---- GraphBounds --------------------------------------------------------

void GraphBounds::include(double time, double value) {
    if (!std::isfinite(time) || !std::isfinite(value)) return;
    minTime_ = std::min(minTime_, time);
    maxTime_ = std::max(maxTime_, time);
    minValue_ = std::min(minValue_, value);
    maxValue_ = std::max(maxValue_, value);
}

void GraphBounds::formUnion(const GraphBounds& other) {
    if (!other.isValid()) return;
    include(other.minTime_, other.minValue_);
    include(other.maxTime_, other.maxValue_);
}

double GraphBounds::cubic(double t, double p0, double p1, double p2, double p3) {
    const double u = 1.0 - t;
    return u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
}

std::vector<double> GraphBounds::extremaParameters(double p0, double p1, double p2, double p3) {
    const double a = p1 - p0;
    const double b = p2 - p1;
    const double c = p3 - p2;
    const double quadratic = a - 2.0 * b + c;
    const double linear = 2.0 * (b - a);
    const double constant = a;

    std::vector<double> roots;
    if (std::fabs(quadratic) < 1e-12) {
        // Degenerates to a line: one root, unless that is flat too.
        if (std::fabs(linear) > 1e-12) roots.push_back(-constant / linear);
    } else {
        const double discriminant = linear * linear - 4.0 * quadratic * constant;
        if (discriminant < 0.0) return {};
        const double root = std::sqrt(discriminant);
        roots.push_back((-linear + root) / (2.0 * quadratic));
        roots.push_back((-linear - root) / (2.0 * quadratic));
    }
    std::vector<double> inside;
    for (double t : roots) {
        if (t > 0.0 && t < 1.0 && std::isfinite(t)) inside.push_back(t);
    }
    return inside;
}

void GraphBounds::includeCubic(
    const Point& p0, const Point& c1, const Point& c2, const Point& p3) {
    for (const Point& point : {p0, c1, c2, p3}) include(point.x, point.y);
    for (double t : extremaParameters(p0.y, c1.y, c2.y, p3.y)) {
        include(cubic(t, p0.x, c1.x, c2.x, p3.x), cubic(t, p0.y, c1.y, c2.y, p3.y));
    }
}

// ---- GraphViewport ------------------------------------------------------

GraphRange GraphViewport::sanitised(const GraphRange& range, std::optional<double> anchor) {
    const double lower = std::isfinite(range.lower) ? range.lower : 0.0;
    const double upper = std::isfinite(range.upper) ? range.upper : lower + 1.0;
    const double span = upper - lower;
    if (!(span < kMinimumSpan)) return GraphRange{lower, upper};

    if (!anchor.has_value() || !std::isfinite(*anchor) || !(span > 0.0)) {
        const double centre = (lower + upper) * 0.5;
        return GraphRange{centre - kMinimumSpan * 0.5, centre + kMinimumSpan * 0.5};
    }
    // Widen to the floor AROUND the anchor, keeping it at the same
    // fraction of the view it was already at.
    const double share = std::min(std::max((*anchor - lower) / span, 0.0), 1.0);
    const double newLower = *anchor - kMinimumSpan * share;
    return GraphRange{newLower, newLower + kMinimumSpan};
}

GraphViewport::GraphViewport(const GraphRange& timeRange, const GraphRange& valueRange)
    : timeRange_(sanitised(timeRange)), valueRange_(sanitised(valueRange)) {}

double GraphViewport::xForTime(double time, double width) const {
    return (time - timeRange_.lower) / timeSpan() * width;
}

double GraphViewport::timeForX(double x, double width) const {
    if (!(width > 0.0)) return timeRange_.lower;
    return timeRange_.lower + (x / width) * timeSpan();
}

double GraphViewport::yForValue(double value, double height) const {
    return height - (value - valueRange_.lower) / valueSpan() * height;
}

double GraphViewport::valueForY(double y, double height) const {
    if (!(height > 0.0)) return valueRange_.lower;
    return valueRange_.lower + ((height - y) / height) * valueSpan();
}

double GraphViewport::valueDeltaForPoints(double points, double height) const {
    if (!(height > 0.0)) return 0.0;
    return (points / height) * valueSpan();
}

double GraphViewport::timeDeltaForPoints(double points, double width) const {
    if (!(width > 0.0)) return 0.0;
    return (points / width) * timeSpan();
}

void GraphViewport::zoom(
    double timeFactor, double valueFactor, double anchorX, double anchorY, double width,
    double height) {
    const double anchorTime = timeForX(anchorX, width);
    const double anchorValue = valueForY(anchorY, height);

    if (timeFactor > 0.0 && std::isfinite(timeFactor)) {
        const double lower = anchorTime - (anchorTime - timeRange_.lower) / timeFactor;
        const double upper = anchorTime + (timeRange_.upper - anchorTime) / timeFactor;
        timeRange_ = sanitised(GraphRange{lower, upper}, anchorTime);
    }
    if (valueFactor > 0.0 && std::isfinite(valueFactor)) {
        const double lower = anchorValue - (anchorValue - valueRange_.lower) / valueFactor;
        const double upper = anchorValue + (valueRange_.upper - anchorValue) / valueFactor;
        valueRange_ = sanitised(GraphRange{lower, upper}, anchorValue);
    }
}

void GraphViewport::pan(double translationX, double translationY, double width, double height) {
    const double timeShift = timeDeltaForPoints(translationX, width);
    const double valueShift = valueDeltaForPoints(translationY, height);
    timeRange_ = GraphRange{timeRange_.lower - timeShift, timeRange_.upper - timeShift};
    // Dragging down should move the content down, which means the visible
    // values go UP. The sign is the flip in `yForValue`, not a choice.
    valueRange_ = GraphRange{valueRange_.lower + valueShift, valueRange_.upper + valueShift};
}

GraphViewport GraphViewport::fitting(const GraphBounds& bounds, double margin) {
    if (!bounds.isValid()) return neutral();
    const double timePad = std::max(bounds.timeSpan() * margin, 0.5);
    const double valuePad = std::max(
        {bounds.valueSpan() * margin, std::fabs(bounds.maxValue()) * 0.08, 0.05});
    return GraphViewport(
        GraphRange{bounds.minTime() - timePad, bounds.maxTime() + timePad},
        GraphRange{bounds.minValue() - valuePad, bounds.maxValue() + valuePad});
}

void GraphViewport::extendToInclude(const GraphBounds& bounds, double margin) {
    if (!bounds.isValid()) return;
    const double timePad = std::max(bounds.timeSpan() * margin, 0.25);
    const double valuePad = std::max(bounds.valueSpan() * margin, 0.05);
    timeRange_ = sanitised(GraphRange{
        std::min(timeRange_.lower, bounds.minTime() - timePad),
        std::max(timeRange_.upper, bounds.maxTime() + timePad)});
    valueRange_ = sanitised(GraphRange{
        std::min(valueRange_.lower, bounds.minValue() - valuePad),
        std::max(valueRange_.upper, bounds.maxValue() + valuePad)});
}

double GraphViewport::gridStep(double span, double targetDivisions) {
    if (!(span > 0.0) || !std::isfinite(span) || !(targetDivisions > 0.0)) return 1.0;
    const double rough = span / targetDivisions;
    const double magnitude = std::pow(10.0, std::floor(std::log10(rough)));
    const double normalised = rough / magnitude;
    double nice = 10.0;
    if (normalised < 1.5) {
        nice = 1.0;
    } else if (normalised < 3.5) {
        nice = 2.0;
    } else if (normalised < 7.5) {
        nice = 5.0;
    }
    return nice * magnitude;
}

std::vector<double> GraphViewport::gridLines(const GraphRange& range, double step, int limit) {
    if (!(step > 0.0) || !std::isfinite(step)) return {};
    const double first = std::ceil(range.lower / step);
    const double last = std::floor(range.upper / step);
    if (!(last >= first) || !(last - first < static_cast<double>(limit))) return {};
    std::vector<double> out;
    for (double index = first; index <= last; index += 1.0) out.push_back(index * step);
    return out;
}

} // namespace umeshcore
